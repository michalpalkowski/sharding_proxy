use starknet::{ContractAddress};
use sharding_tests::sharding::StorageSlotWithContract;
use sharding_tests::sharding::CRDTStorageSlot;

#[derive(Drop, Serde, Hash, Copy, Debug, PartialEq, starknet::Store)]
pub enum CRDType {
    Add,
    #[default]
    Lock,
    Set,
}

trait CRDTypeTrait {
    fn verify_crd_type(self: Option<CRDType>, crd_type: CRDType);
}

impl CRDTypeImpl of CRDTypeTrait {
    fn verify_crd_type(self: Option<CRDType>, crd_type: CRDType) {
        match crd_type {
            CRDType::Add => {
                assert(
                    self == Option::None || self == Option::Some(CRDType::Add),
                    'Sharding already initialized',
                );
            },
            CRDType::Lock => { assert(self == Option::None, 'Sharding already initialized'); },
            CRDType::Set => {
                assert(
                    self == Option::None || self == Option::Some(CRDType::Set),
                    'Sharding already initialized',
                );
            },
        }
    }
}

#[starknet::interface]
pub trait IContractComponent<TContractState> {
    fn initialize_shard(
        ref self: TContractState,
        sharding_contract_address: ContractAddress,
        contract_slots_changes: Span<StorageSlotWithContract>,
    );
    fn update_state(
        ref self: TContractState, storage_changes: Array<CRDTStorageSlot>, shard_id: felt252, contract_address: ContractAddress,
    );
}

#[starknet::component]
pub mod contract_component {
    use starknet::{
        get_caller_address, ContractAddress,
        storage::{StorageMapReadAccess, StorageMapWriteAccess, Map},
    };
    use core::starknet::SyscallResultTrait;
    use starknet::syscalls::storage_write_syscall;
    use starknet::syscalls::storage_read_syscall;
    use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
    use sharding_tests::sharding::StorageSlotWithContract;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use sharding_tests::sharding::CRDTStorageSlot;
    use starknet::storage_access::StorageAddress;
    use super::CRDType;
    use super::CRDTypeTrait;
    type shard_id = felt252;

    #[storage]
    pub struct Storage {
        slots: Map<(ContractAddress, felt252), (Option<CRDType>, felt252)>,
        contract_address: ContractAddress,
        sharding_contract_address: ContractAddress,
        locked_slots: Map<StorageSlotWithContract, bool>,
        add_slots: Map<StorageSlotWithContract, bool>,
        set_slots: Map<StorageSlotWithContract, bool>,
        initializer_contract_address: ContractAddress,
        shard_id: Map<ContractAddress, shard_id>,
        shard_id_for_slot: Map<StorageSlotWithContract, shard_id>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ContractSlotUpdated: ContractSlotUpdated,
        ContractComponentInitialized: ContractComponentInitialized,
        ContractComponentUpdated: ContractComponentUpdated,
    }

    #[derive(Drop, starknet::Event, Clone)]
    pub struct ContractSlotUpdated {
        pub contract_address: ContractAddress,
        pub shard_id: felt252,
        pub slots_to_change: Array<CRDTStorageSlot>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractComponentInitialized {
        pub contract_address: ContractAddress,
        pub sharding_contract_address: ContractAddress,
        pub initializer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractComponentUpdated {
        pub storage_changes: Array<CRDTStorageSlot>,
    }

    pub mod Errors {
        pub const NOT_INITIALIZED: felt252 = 'Component: Not initialized';
        pub const ALREADY_INITIALIZED: felt252 = 'Component: Already initialized';
        pub const STORAGE_LOCKED: felt252 = 'Component: Storage is locked';
        pub const STORAGE_UNLOCKED: felt252 = 'Component: Storage is unlocked';
        pub const SHARD_ID_MISMATCH: felt252 = 'Component: Shard id mismatch';
        pub const SHARD_ID_NOT_SET: felt252 = 'Component: Shard id not set';
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'Component: No contracts';
        pub const NO_SLOTS_TO_UPDATE: felt252 = 'No slots to update';
    }

    #[embeddable_as(ContractComponentImpl)]
    impl ContractImpl<
        TContractState, +HasComponent<TContractState>,
    > of super::IContractComponent<ComponentState<TContractState>> {
        fn initialize_shard(
            ref self: ComponentState<TContractState>,
            sharding_contract_address: ContractAddress,
            contract_slots_changes: Span<StorageSlotWithContract>,
        ) {
            let caller = get_caller_address();
            let current_shard_id = self.shard_id.read(caller);
            let new_shard_id = current_shard_id + 1;
            self.shard_id.write(caller, new_shard_id);

            println!(
                "Initializing shard for caller: {:?}, new shard_id: {:?}", caller, new_shard_id,
            );

            for storage_slot in contract_slots_changes {
                let storage_slot = *storage_slot;
                let crd_type = storage_slot.crd_type;

                let (prev_crd_type, init_count) = self
                    .slots
                    .read((storage_slot.contract_address, storage_slot.slot));

                prev_crd_type.verify_crd_type(crd_type);

                println!("Locking storage slots");
                // Lock this storage key
                self
                    .slots
                    .write(
                        (storage_slot.contract_address, storage_slot.slot),
                        (Option::Some(crd_type), init_count + 1),
                    );
                self.shard_id_for_slot.write(storage_slot, new_shard_id);
                println!("Locked slot: {:?} with shard_id: {:?}", storage_slot, new_shard_id);
            };
            // Emit initialization event
            self.initializer_contract_address.write(caller);

            let sharding_dispatcher = IShardingDispatcher {
                contract_address: sharding_contract_address,
            };
            sharding_dispatcher.initialize_sharding(contract_slots_changes);

            self.emit(ContractComponentInitialized { contract_address: caller, sharding_contract_address, initializer: caller });
        }

        fn update_state(
            ref self: ComponentState<TContractState>,
            storage_changes: Array<CRDTStorageSlot>,
            shard_id: felt252,
            contract_address: ContractAddress,
        ) {
            assert(storage_changes.len() != 0, Errors::NO_CONTRACTS_SUBMITTED);
            let mut slots_to_change = ArrayTrait::new();

            for storage_change in storage_changes.span() {
                let storage_key = *storage_change.key;
                let storage_value = *storage_change.value;
                let crd_type = *storage_change.crd_type;

                // Create a StorageSlot to check if it's locked
                let slot = StorageSlotWithContract {
                    contract_address: contract_address, slot: storage_key, crd_type,
                };

                let slot_shard_id = self.shard_id_for_slot.read(slot);
                let (prev_crd_type, _) = self
                    .slots
                    .read((slot.contract_address, slot.slot));

                println!(
                    "Checking slot (Lock): {:?}, slot_shard_id: {:?}, contract_shard_id: {:?}, prev_crd_type: {:?}",
                    slot,
                    slot_shard_id,
                    shard_id,
                    prev_crd_type,
                );

                if slot_shard_id == shard_id && prev_crd_type == Option::Some(crd_type) {
                    slots_to_change
                        .append(
                            CRDTStorageSlot {
                                key: storage_key, value: storage_value, crd_type,
                            },
                        );
                } else {
                    println!(
                        "Skipping slot with mismatched shard_id or not locked: {:?}", slot,
                    );
                }
            };

            println!("Updating contract with {} slots", slots_to_change.len());

            if slots_to_change.len() == 0 {
                println!("No slots to update");
            };

            self.update_shard(slots_to_change.clone());

            for slot_to_unlock in slots_to_change.span() {
                // Create a StorageSlot to unlock
                let slot = StorageSlotWithContract {
                    contract_address: contract_address,
                    slot: *slot_to_unlock.key,
                    crd_type: *slot_to_unlock.crd_type,
                };
                println!("Unlocking slot: {:?}", slot);
                let (prev_crd_type, init_count) = self
                    .slots
                    .read((slot.contract_address, slot.slot));
                assert(init_count != 0, Errors::STORAGE_UNLOCKED);
                if init_count - 1 == 0 {
                    self.slots.write((slot.contract_address, slot.slot), (Option::None, 0));
                } else {
                    self
                        .slots
                        .write(
                            (slot.contract_address, slot.slot),
                            (prev_crd_type, init_count - 1),
                        );
                }
            };
            self.emit(ContractSlotUpdated { contract_address, shard_id, slots_to_change });
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn assert_initialized(self: @ComponentState<TContractState>) {
            let sharding_address = self.sharding_contract_address.read();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(sharding_address != zero_address, Errors::NOT_INITIALIZED);
        }

        fn update_shard(
            ref self: ComponentState<TContractState>, storage_changes: Array<CRDTStorageSlot>,
        ) {
            let sharding_address = self.sharding_contract_address.read();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(sharding_address != zero_address, Errors::NOT_INITIALIZED);

            for storage_change in storage_changes.span() {
                let key = *storage_change.key;
                let value = *storage_change.value;
                let crd_type = *storage_change.crd_type;

                let storage_address: StorageAddress = key.try_into().unwrap();

                match crd_type {
                    CRDType::Lock => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                        println!("Lock operation: key={}, value={}", key, value);
                    },
                    CRDType::Set => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                        println!("Set operation: key={}, value={}", key, value);
                    },
                    CRDType::Add => {
                        let current_value = storage_read_syscall(0, storage_address)
                            .unwrap_syscall();
                        let new_value = current_value + value;
                        storage_write_syscall(0, storage_address, new_value).unwrap_syscall();
                        println!(
                            "Add operation: key={}, current_value={}, added_value={}, new_value={}",
                            key,
                            current_value,
                            value,
                            new_value,
                        );
                    },
                }
            };
            self.emit(ContractComponentUpdated { storage_changes });
        }
    }
}
