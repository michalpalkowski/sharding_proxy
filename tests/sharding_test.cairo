use snforge_std::EventSpyTrait;
use core::traits::Into;
use core::result::ResultTrait;
use core::poseidon::PoseidonImpl;
use openzeppelin_testing::constants as c;
use snforge_std as snf;
use starknet::ContractAddress;
use snforge_std::{ContractClassTrait, EventSpy, EventSpyAssertionsTrait};
use sharding_tests::sharding::IShardingDispatcher;
use sharding_tests::sharding::IShardingDispatcherTrait;
use sharding_tests::sharding::sharding::{Event as ShardingEvent, ShardInitialized};

use sharding_tests::contract_component::IContractComponentDispatcher;
use sharding_tests::contract_component::IContractComponentDispatcherTrait;
use sharding_tests::contract_component::contract_component::{
    Event as ContractComponentEvent, ContractSlotUpdated,
};

use sharding_tests::config::IConfigDispatcher;
use sharding_tests::config::IConfigDispatcherTrait;

use sharding_tests::test_contract::ITestContractDispatcher;
use sharding_tests::test_contract::ITestContractDispatcherTrait;
use sharding_tests::test_contract::test_contract::{Event as TestContractEvent, GameFinished};
use sharding_tests::shard_output::{ShardOutput, ContractChanges};

use sharding_tests::contract_component::CRDType;
use sharding_tests::contract_component::CRDTypeTrait;

const NOT_LOCKED_SLOT_VALUE: felt252 = 0x2;
const NOT_LOCKED_SLOT_ADDRESS: felt252 = 0x123;

#[derive(Drop)]
struct TestSetup {
    sharding_spy: snf::EventSpy,
    test_spy: snf::EventSpy,
    shard_dispatcher: IShardingDispatcher,
    sharding_contract_config_dispatcher: IConfigDispatcher,
    test_contract_dispatcher: ITestContractDispatcher,
    test_contract_component_dispatcher: IContractComponentDispatcher,
}

fn setup() -> TestSetup {
    // Deploy the sharding contract
    let (sharding, mut sharding_spy) = deploy_contract_with_owner(c::OWNER().into(), "sharding");

    // Deploy the test contract
    let (test_contract, mut test_spy) = deploy_contract_with_owner(
        c::OWNER().into(), "test_contract",
    );

    let shard_dispatcher = IShardingDispatcher { contract_address: sharding };
    let sharding_contract_config_dispatcher = IConfigDispatcher { contract_address: sharding };

    let test_contract_dispatcher = ITestContractDispatcher { contract_address: test_contract };
    let test_contract_component_dispatcher = IContractComponentDispatcher {
        contract_address: test_contract,
    };

    // Register the test contract as an operator
    snf::start_cheat_caller_address(
        sharding_contract_config_dispatcher.contract_address, c::OWNER(),
    );
    sharding_contract_config_dispatcher
        .register_operator(test_contract_component_dispatcher.contract_address);
    snf::stop_cheat_caller_address(sharding_contract_config_dispatcher.contract_address);

    TestSetup {
        sharding_spy,
        test_spy,
        shard_dispatcher,
        sharding_contract_config_dispatcher,
        test_contract_dispatcher,
        test_contract_component_dispatcher,
    }
}

fn deploy_contract_with_owner(
    owner: felt252, contract_name: ByteArray,
) -> (ContractAddress, EventSpy) {
    let contract = match snf::declare(contract_name).unwrap() {
        snf::DeclareResult::Success(contract) => contract,
        _ => core::panic_with_felt252('AlreadyDeclared not expected'),
    };
    let calldata = array![owner];
    let (contract_address, _) = contract.deploy(@calldata).unwrap();

    let mut spy = snf::spy_events();
    (contract_address, spy)
}

fn get_state_update(
    test_contract_address: felt252, storage_slot: felt252, storage_value: felt252,
) -> Array<felt252> {
    let mut shard_output = ShardOutput {
        state_diff: array![
            ContractChanges {
                addr: test_contract_address,
                nonce: 0,
                class_hash: Option::None,
                storage_changes: array![(storage_slot, storage_value)],
            },
            // Not locked slot, should not be updated, so we add it this dummy value to the state
            // diff to verify that it is not updated
            ContractChanges {
                addr: test_contract_address,
                nonce: 0,
                class_hash: Option::None,
                storage_changes: array![(NOT_LOCKED_SLOT_ADDRESS, NOT_LOCKED_SLOT_VALUE)],
            },
        ],
    };
    let mut snos_output = array![];
    shard_output.serialize(ref snos_output);
    println!("snos_output: {:?}", snos_output);
    snos_output
}


fn initialize_shard(mut setup: TestSetup, crd_type: CRDType) -> TestSetup {
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    let contract_slots_changes = setup.test_contract_dispatcher.get_storage_slots(crd_type);

    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);

    let expected_init = ShardInitialized {
        initializer: setup.test_contract_component_dispatcher.contract_address,
        shard_id: shard_id,
        storage_slots: array![contract_slots_changes].span(),
    };

    setup
        .sharding_spy
        .assert_emitted(
            @array![
                (
                    setup.shard_dispatcher.contract_address,
                    ShardingEvent::ShardInitialized(expected_init),
                ),
            ],
        );

    setup
}

#[test]
fn test_update_state() {
    // Deploy the sharding contract
    let mut setup = setup();

    let expected_slot_value = 5;
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        expected_slot_value,
    );
    // Initialize the shard by connecting the test contract to the sharding system
    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 0, "Counter is not set");

    // Apply the state update to the sharding system with shard ID 1
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    //Counter is updated by snos_output
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == expected_slot_value, "Counter is not set");
    println!("counter: {:?}", counter);

    // Verify that an unchanged storage slot remains at its default value
    let unchanged_slot = setup.test_contract_dispatcher.read_storage_slot(NOT_LOCKED_SLOT_ADDRESS);

    assert!(unchanged_slot == 0, "Unchanged slot is not set");

    //TODO! we need to talk about silent consent to not update unsent slots

    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let events = setup.test_spy.get_events();
    println!("events: {:?}", events);
}

#[test]
fn test_ending_event() {
    let (test_contract, mut test_spy) = deploy_contract_with_owner(
        c::OWNER().into(), "test_contract",
    );

    let test_contract_dispatcher = ITestContractDispatcher { contract_address: test_contract };

    snf::start_cheat_caller_address(test_contract_dispatcher.contract_address, c::OWNER());
    test_contract_dispatcher.increment();
    test_contract_dispatcher.increment();
    test_contract_dispatcher.increment();

    let expected_increment = GameFinished { caller: c::OWNER(), shard_id: 0 };

    test_spy
        .assert_emitted(
            @array![
                (
                    test_contract_dispatcher.contract_address,
                    TestContractEvent::GameFinished(expected_increment),
                ),
            ],
        );
}

#[test]
fn test_update_state_with_add_operation() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    let mut setup = initialize_shard(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Set initial counter value
    setup.test_contract_dispatcher.set_counter(10);
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter is not set to initial value");

    // Create SNOS output with Add operation
    let mut snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply the state update with Add operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Verify that the counter was incremented by 5 (from SNOS output) to become 15
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 15, "Counter was not incremented correctly");
    println!("Counter after Add operation: {:?}", counter);
}

#[test]
fn test_update_state_with_set_operation() {
    let mut setup = setup();

    let mut setup = initialize_shard(
        setup, CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Set initial counter value to 20
    setup.test_contract_dispatcher.set_counter(20);
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 20, "Counter is not set to initial value");

    // Create SNOS output with Set operation
    let mut snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply the state update with Set operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Verify that the counter was set to 5 (from SNOS output), replacing the previous value of 20
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter was not set correctly");
    println!("Counter after Set operation: {:?}", counter);
}

#[test]
fn test_multiple_crd_operations() {
    let mut setup = setup();

    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Set initial counter value to 0
    setup.test_contract_dispatcher.set_counter(0);

    // Create SNOS output
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply state update with Lock operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Verify counter is 5 after update
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not set correctly after update");
    println!("Counter after Lock operation: {:?}", counter);

    // Initialize a new shard with Add operation type
    let mut setup = initialize_shard(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply state update with Add operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    // Verify counter is 10 after Add operation (5 + 5)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter is not set correctly after Add operation");
    println!("Counter after Add operation: {:?}", counter);

    // Initialize a new shard with Set operation type
    let mut setup = initialize_shard(
        setup, CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // Apply state update with Set operation
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 3);

    // Verify counter is 5 after Set operation (overwriting previous value)
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not set correctly after Set operation");
    println!("Counter after Set operation: {:?}", counter);

    println!("All CRDT operations completed successfully");
}

#[test]
#[should_panic(expected: ('L: Sharding already initialized',))]
fn test_lock_after_lock_fails() {
    let mut setup = setup();

    // Initialize the shard with Lock operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    let contract_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())));

    // First initialization with Lock
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Second initialization with Lock - should fail
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );
}

#[test]
#[should_panic(expected: ('L: Sharding already initialized',))]
fn test_lock_after_add_fails() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    // First initialization with Add
    let add_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );

    // Second initialization with Lock - should fail
    let lock_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![lock_slots_changes].span(),
        );
}

#[test]
#[should_panic(expected: ('L: Sharding already initialized',))]
fn test_lock_after_set_fails() {
    let mut setup = setup();

    // Initialize the shard with Set operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    // First initialization with Set
    let set_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );

    // Second initialization with Lock - should fail
    let lock_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![lock_slots_changes].span(),
        );
}

#[test]
#[should_panic(expected: ('S: Sharding already initialized',))]
fn test_set_after_add_fails() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    // First initialization with Add
    let add_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );

    // Second initialization with Set - should fail
    let set_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );
}

#[test]
#[should_panic(expected: ('A: Sharding already initialized',))]
fn test_add_after_set_fails() {
    let mut setup = setup();

    // Initialize the shard with Set operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    // First initialization with Set
    let set_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );

    // Second initialization with Add - should fail
    let add_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );
}

#[test]
fn test_two_times_add() {
    let mut setup = setup();

    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    // Test Add after Add - should work
    let add_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );

    // Second initialization with Add - should work
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![add_slots_changes].span(),
        );

    // Verify shard ID incremented
    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);
    assert!(shard_id == 2, "Shard ID should be 2 after second initialization");

    println!("All valid CRD combinations passed");
}


#[test]
fn test_two_times_set() {
    let mut setup = setup();

    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    // Test Set after Set - should work
    let set_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Set((0.try_into().unwrap(), 0.try_into().unwrap())));
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );

    // Second initialization with Set - should work
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![set_slots_changes].span(),
        );

    // Verify shard ID incremented
    let shard_id = setup
        .shard_dispatcher
        .get_shard_id(setup.test_contract_dispatcher.contract_address);
    assert!(shard_id == 2, "Shard ID should be 2 after second initialization");

    println!("All valid CRD combinations passed");
}


#[test]
fn test_too_many_lock_updates_empty_event() {
    let mut setup = setup();

    // Initialize the shard with Lock operation type
    let mut setup = initialize_shard(
        setup, CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
    );

    // Create SNOS output
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // First update_state - should work
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    let expected_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 1,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(
                        CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())),
                    )
                    .slot(),
                5,
            ),
        ],
    };

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_event.clone()),
                ),
            ],
        );

    // Verify counter is updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly");

    // Second update_state - should fail because the slot is already unlocked
    // This simulates trying to update more times than the init_count
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    let expected_empty_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 1,
        slots_to_change: array![],
    };

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_empty_event),
                ),
            ],
        );
}

#[test]
fn test_too_many_add_updates_empty_event() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    let mut setup = initialize_shard(
        setup, CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())),
    );
    // Create SNOS output
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // First update_state - should work
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    let expected_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 1,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
                    .slot(),
                5,
            ),
        ],
    };

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_event.clone()),
                ),
            ],
        );

    // Verify counter is updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly");

    // Second update_state - should fail because the slot is already unlocked
    // This simulates trying to update more times than the init_count
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    let expected_empty_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 1,
        slots_to_change: array![],
    };

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_empty_event),
                ),
            ],
        );
}

#[test]
fn test_two_times_init_add_and_two_updates() {
    let mut setup = setup();

    // Initialize the shard with Add operation type
    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    let contract_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())));

    // Initialize the shard
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Initialize the shard again
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Create SNOS output
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // First update_state - should work
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    let expected_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 2,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
                    .slot(),
                5,
            ),
        ],
    };

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_event.clone()),
                ),
            ],
        );

    // Verify counter is updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly");

    // Second update_state - should work
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    let expected_second_update_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 2,
        slots_to_change: array![
            (
                setup
                    .test_contract_dispatcher
                    .get_storage_slots(CRDType::Add((0.try_into().unwrap(), 0.try_into().unwrap())))
                    .slot(),
                5,
            ),
        ],
    };

    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 10, "Counter is not updated correctly");

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_second_update_event),
                ),
            ],
        );

    // Third update_state - should return empty event
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    let expected_empty_event = ContractSlotUpdated {
        contract_address: setup.test_contract_dispatcher.contract_address,
        shard_id: 2,
        slots_to_change: array![],
    };

    setup
        .test_spy
        .assert_emitted(
            @array![
                (
                    setup.test_contract_component_dispatcher.contract_address,
                    ContractComponentEvent::ContractSlotUpdated(expected_empty_event),
                ),
            ],
        );
}


#[test]
fn test_multiple_initializations_and_updates() {
    let mut setup = setup();

    snf::start_cheat_caller_address(
        setup.test_contract_component_dispatcher.contract_address, c::OWNER(),
    );

    // Initialize the shard multiple times with Lock operation type
    let contract_slots_changes = setup
        .test_contract_dispatcher
        .get_storage_slots(CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())));

    // First initialization
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Create SNOS output
    let snos_output = get_state_update(
        setup.test_contract_dispatcher.contract_address.into(),
        setup
            .test_contract_dispatcher
            .get_storage_slots(CRDType::Lock((0.try_into().unwrap(), 0.try_into().unwrap())))
            .slot(),
        5,
    );

    // First update_state
    snf::start_cheat_caller_address(
        setup.shard_dispatcher.contract_address,
        setup.test_contract_component_dispatcher.contract_address,
    );
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 1);

    // Verify counter is updated
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly after first update");

    // Second initialization
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Second update_state
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 2);

    // Verify counter is updated again
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly after second update");

    // Third initialization
    setup
        .test_contract_component_dispatcher
        .initialize_shard(
            setup.shard_dispatcher.contract_address, array![contract_slots_changes].span(),
        );

    // Third update_state
    setup.shard_dispatcher.update_contract_state(snos_output.span(), 3);

    // Verify counter is updated again
    let counter = setup.test_contract_dispatcher.get_counter();
    assert!(counter == 5, "Counter is not updated correctly after third update");

    println!("Multiple initializations and updates completed successfully");
}
