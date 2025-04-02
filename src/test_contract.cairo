use sharding_tests::sharding::StorageSlotWithContract;
use sharding_tests::contract_component::CRDType;

#[starknet::interface]
pub trait ITestContract<TContractState> {
    fn increment(ref self: TContractState);

    fn get_counter(ref self: TContractState) -> felt252;

    fn set_counter(ref self: TContractState, value: felt252);

    fn read_storage_slot(ref self: TContractState, key: felt252) -> felt252;

    fn get_storage_slots(ref self: TContractState, crd_type: CRDType) -> StorageSlotWithContract;
}

#[starknet::contract]
pub mod test_contract {
    use core::poseidon::{PoseidonImpl};
    use openzeppelin::access::ownable::{
        OwnableComponent as ownable_cpt, OwnableComponent::InternalTrait as OwnableInternal,
    };
    use starknet::{ContractAddress, get_contract_address};
    use core::starknet::SyscallResultTrait;
    use super::ITestContract;
    use sharding_tests::contract_component::contract_component;
    use sharding_tests::sharding::StorageSlotWithContract;
    use sharding_tests::contract_component::CRDType;
    use starknet::syscalls::storage_read_syscall;

    use starknet::{
        get_caller_address, storage::{StoragePointerReadAccess, StoragePointerWriteAccess},
        event::EventEmitter,
    };

    component!(path: ownable_cpt, storage: ownable, event: OwnableEvent);
    component!(
        path: contract_component, storage: contract_component, event: ContractComponentEvent,
    );

    #[abi(embed_v0)]
    impl ContractComponentImpl =
        contract_component::ContractComponentImpl<ContractState>;

    impl ContractComponentInternalImpl = contract_component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        counter: felt252,
        #[substorage(v0)]
        ownable: ownable_cpt::Storage,
        #[substorage(v0)]
        contract_component: contract_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        TestContractInitialized: TestContractInitialized,
        Increment: Increment,
        GameFinished: GameFinished,
        TestContractUpdated: TestContractUpdated,
        #[flat]
        OwnableEvent: ownable_cpt::Event,
        #[flat]
        ContractComponentEvent: contract_component::Event,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TestContractInitialized {
        pub initializer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct TestContractUpdated {
        pub storage_changes: Span<(felt252, felt252)>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Increment {
        pub caller: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct GameFinished {
        pub caller: ContractAddress,
    }

    pub mod Errors {
        pub const TEST_CONTRACT_ERROR: felt252 = 'TestContract: test error';
        pub const ALREADY_INITIALIZED: felt252 = 'TestContract: alr initialized';
        pub const NOT_INITIALIZED: felt252 = 'TestContract: not initialized';
        pub const STORAGE_LOCKED: felt252 = 'TestContract: storage is locked';
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl TestContractImpl of ITestContract<ContractState> {
        fn increment(ref self: ContractState) {
            self.counter.write(self.counter.read() + 1);

            let caller = get_caller_address();
            self.emit(Increment { caller });

            if self.counter.read() == 3 {
                self.emit(GameFinished { caller });
            }
        }

        fn get_counter(ref self: ContractState) -> felt252 {
            let counter = self.counter.read();
            counter
        }

        fn set_counter(ref self: ContractState, value: felt252) {
            self.counter.write(value);
        }

        fn read_storage_slot(ref self: ContractState, key: felt252) -> felt252 {
            storage_read_syscall(0, key.try_into().unwrap()).unwrap_syscall()
        }
        
        fn get_storage_slots(
            ref self: ContractState, crd_type: CRDType,
        ) -> StorageSlotWithContract {
            StorageSlotWithContract {
                contract_address: get_contract_address(), slot: selector!("counter"), crd_type,
            }
        }
    }
}
