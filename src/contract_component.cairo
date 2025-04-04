use starknet::{ContractAddress};

#[derive(Drop, Serde, Hash, Copy, Debug, PartialEq, starknet::Store)]
pub enum CRDType {
    Add: (ContractAddress, felt252),
    #[default]
    Lock: (ContractAddress, felt252),
    Set: (ContractAddress, felt252),
}

pub trait CRDTypeTrait {
    fn verify_crd_type(self: Option<CRDType>, crd_type: CRDType);
    fn contract_address(self: CRDType) -> ContractAddress;
    fn slot(self: CRDType) -> felt252;
}

impl CRDTypeImpl of CRDTypeTrait {
    fn verify_crd_type(self: Option<CRDType>, crd_type: CRDType) {
        let error_msg = match crd_type {
            CRDType::Add => 'A: Sharding already initialized',
            CRDType::Lock => 'L: Sharding already initialized',
            CRDType::Set => 'S: Sharding already initialized',
        };

        match crd_type {
            CRDType::Add => {
                let is_valid = match self {
                    Option::None => true,
                    Option::Some(prev) => match prev {
                        CRDType::Add => true,
                        _ => false,
                    },
                };
                assert(is_valid, error_msg);
            },
            CRDType::Lock => { assert(self == Option::None, error_msg); },
            CRDType::Set => {
                let is_valid = match self {
                    Option::None => true,
                    Option::Some(prev) => match prev {
                        CRDType::Set => true,
                        _ => false,
                    },
                };
                assert(is_valid, error_msg);
            },
        }
    }
    fn contract_address(self: CRDType) -> ContractAddress {
        match self {
            CRDType::Add((address, _)) | CRDType::Lock((address, _)) |
            CRDType::Set((address, _)) => address,
        }
    }

    fn slot(self: CRDType) -> felt252 {
        match self {
            CRDType::Add((_, slot)) | CRDType::Lock((_, slot)) | CRDType::Set((_, slot)) => slot,
        }
    }
}

#[starknet::interface]
pub trait IContractComponent<TContractState> {
    fn initialize_shard(
        ref self: TContractState,
        sharding_contract_address: ContractAddress,
        contract_slots_changes: Span<CRDType>,
    );
    fn update_shard_state(
        ref self: TContractState,
        storage_changes: Array<(felt252, felt252)>,
        shard_id: felt252,
        contract_address: ContractAddress,
    );
    fn get_shard_id(ref self: TContractState, contract_address: ContractAddress) -> felt252;
}

#[starknet::component]
pub mod contract_component {
    use starknet::{
        get_caller_address, ContractAddress, get_contract_address,
        storage::{StorageMapReadAccess, StorageMapWriteAccess, Map},
    };
    use core::starknet::SyscallResultTrait;
    use starknet::syscalls::storage_write_syscall;
    use starknet::syscalls::storage_read_syscall;
    use sharding_tests::sharding::{IShardingDispatcher, IShardingDispatcherTrait};
    use sharding_tests::sharding::StorageSlotWithContract;
    use core::starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::storage_access::StorageAddress;
    use super::CRDType;
    use super::CRDTypeTrait;

    type shard_id = felt252;
    type slot_value = felt252;
    type init_count = felt252;

    #[storage]
    pub struct Storage {
        slots: Map<slot_value, (Option<CRDType>, init_count)>,
        sharding_contract_address: ContractAddress,
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
        pub slots_to_change: Array<(felt252, felt252)>,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractComponentInitialized {
        pub contract_address: ContractAddress,
        pub sharding_contract_address: ContractAddress,
        pub initializer: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ContractComponentUpdated {
        pub storage_changes: Array<(felt252, felt252)>,
    }

    pub mod Errors {
        pub const NOT_INITIALIZED: felt252 = 'Component: Not initialized';
        pub const STORAGE_UNLOCKED: felt252 = 'Component: Storage is unlocked';
        pub const NO_CONTRACTS_SUBMITTED: felt252 = 'Component: No contracts';
    }

    #[embeddable_as(ContractComponentImpl)]
    impl ContractImpl<
        TContractState, +HasComponent<TContractState>,
    > of super::IContractComponent<ComponentState<TContractState>> {
        fn initialize_shard(
            ref self: ComponentState<TContractState>,
            sharding_contract_address: ContractAddress,
            contract_slots_changes: Span<CRDType>,
        ) {
            let caller = get_caller_address();
            self.sharding_contract_address.write(sharding_contract_address);
            let current_shard_id = self.shard_id.read(caller);

            let new_shard_id = current_shard_id + 1;
            self.shard_id.write(caller, new_shard_id);

            println!("Initializing shard for caller: {:?}", caller);

            for crd_type in contract_slots_changes {
                let crd_type = *crd_type;

                let (prev_crd_type, init_count) = self.slots.read(crd_type.slot());

                prev_crd_type.verify_crd_type(crd_type);

                let slot = StorageSlotWithContract {
                    contract_address: crd_type.contract_address(), slot: crd_type.slot(),
                };

                self.slots.write(crd_type.slot(), (Option::Some(crd_type), init_count + 1));
                self.shard_id_for_slot.write(slot, new_shard_id);
                println!("Locked slot: {:?} with shard_id: {:?}", crd_type, new_shard_id);
            };

            // Emit initialization event
            let sharding_dispatcher = IShardingDispatcher {
                contract_address: sharding_contract_address,
            };
            sharding_dispatcher.initialize_sharding(contract_slots_changes);

            self
                .emit(
                    ContractComponentInitialized {
                        contract_address: get_contract_address(),
                        sharding_contract_address,
                        initializer: caller,
                    },
                );
        }

        fn update_shard_state(
            ref self: ComponentState<TContractState>,
            storage_changes: Array<(felt252, felt252)>,
            shard_id: felt252,
            contract_address: ContractAddress //todo: remove this
        ) {
            assert(storage_changes.len() != 0, Errors::NO_CONTRACTS_SUBMITTED);
            let mut slots_to_change = ArrayTrait::new();

            let sharding_address = self.sharding_contract_address.read();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(sharding_address != zero_address, Errors::NOT_INITIALIZED);

            for storage_change in storage_changes.span() {
                let (storage_key, storage_value) = *storage_change;

                // Create a StorageSlot to check if it's locked
                let slot = StorageSlotWithContract {
                    contract_address: contract_address, slot: storage_key,
                };

                let slot_shard_id = self.shard_id_for_slot.read(slot);
                let (crd_type, _) = self.slots.read(slot.slot);

                println!(
                    "Checking slot (Lock): {:?}, slot_shard_id: {:?}, contract_shard_id: {:?}, crd_type: {:?}",
                    slot,
                    slot_shard_id,
                    shard_id,
                    crd_type,
                );

                if slot_shard_id == shard_id && crd_type != Option::None {
                    slots_to_change.append((storage_key, storage_value));
                } else {
                    println!("Skipping slot with mismatched shard_id or not locked: {:?}", slot);
                }
            };

            if slots_to_change.len() == 0 {
                println!("WARNING: No slots to update for contract: {:?}", contract_address);
            };

            self.update_shard(slots_to_change.clone(), contract_address);

            for slot_to_unlock in slots_to_change.span() {
                let (storage_key, _) = *slot_to_unlock;
                // Create a StorageSlot to unlock
                let slot = StorageSlotWithContract {
                    contract_address: contract_address, slot: storage_key,
                };

                println!("Unlocking slot: {:?}", slot);
                let (crd_type, init_count) = self.slots.read(slot.slot);
                assert(init_count != 0, Errors::STORAGE_UNLOCKED);

                let new_init_count = init_count - 1;

                if new_init_count == 0 {
                    self.slots.write(slot.slot, (Option::None, 0));
                } else {
                    self.slots.write(slot.slot, (crd_type, new_init_count));
                }
            };
            self.emit(ContractSlotUpdated { contract_address, shard_id, slots_to_change });
        }

        fn get_shard_id(
            ref self: ComponentState<TContractState>, contract_address: ContractAddress,
        ) -> felt252 {
            self.shard_id.read(contract_address)
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn update_shard(
            ref self: ComponentState<TContractState>,
            storage_changes: Array<(felt252, felt252)>,
            contract_address: ContractAddress,
        ) {
            for storage_change in storage_changes.span() {
                let (key, value) = *storage_change;
                let storage_address: StorageAddress = key.try_into().unwrap();

                let (crd_type, _) = self.slots.read(key);
                assert(crd_type != Option::None, 'CRDType not found');
                let crd_type = crd_type.unwrap();

                match crd_type {
                    CRDType::Lock => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                        println!("Lock: Updating key={}, with value={}", key, value);
                    },
                    CRDType::Set => {
                        storage_write_syscall(0, storage_address, value).unwrap_syscall();
                        println!("Set: Updating key={}, with value={}", key, value);
                    },
                    CRDType::Add => {
                        let current_value = storage_read_syscall(0, storage_address)
                            .unwrap_syscall();
                        let new_value = current_value + value;
                        storage_write_syscall(0, storage_address, new_value).unwrap_syscall();
                        println!(
                            "Add: Updating key={}, current_value={}, added_value={}, new_value={}",
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
