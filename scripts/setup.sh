#!/bin/bash


declare_contract() {
  local contract_name=$1
  local class_hash_file=$2

  echo "Declaring $contract_name contrac+t..."
  output=$(sncast declare \
    --contract-name $contract_name \
    --url http://localhost:5050/ \
    --fee-token eth)

  class_hash=$(echo "$output" | grep "class_hash" | awk '{print $2}')
  echo $class_hash > $class_hash_file
  echo "$contract_name class_hash: $class_hash"
}

# Function to deploy a contract with retry policy
deploy_contract() {
  local class_hash_file=$1
  local contract_address_file=$2
  local calldata=$3
  local max_retries=5
  local attempt=0

  class_hash=$(cat $class_hash_file)

  while [ $attempt -lt $max_retries ]; do
    echo "Deploying contract with class_hash $class_hash (Attempt $((attempt + 1))/$max_retries)..."
    output=$(sncast deploy \
      --class-hash $class_hash \
      --fee-token eth \
      --constructor-calldata $calldata)

    if echo "$output" | grep -q "contract_address"; then
      contract_address=$(echo "$output" | grep "contract_address" | awk '{print $2}')
      echo $contract_address > $contract_address_file
      echo "Contract deployed at address: $contract_address"
      break
    else
      echo "Deployment failed, retrying..."
      attempt=$((attempt + 1))
      sleep 10
    fi
  done

  if [ $attempt -eq $max_retries ]; then
    echo "Deployment failed after $max_retries attempts."
    exit 1
  fi

  sleep 5
}

# Function to invoke a function on a contract
invoke_function() {
  local contract_address_file=$1
  local function_name=$2
  local calldata=$3

  contract_address=$(cat $contract_address_file)

  echo "Invoking $function_name on contract at address $contract_address..."
  sncast invoke \
    --contract-address $contract_address \
    --function $function_name \
    --fee-token eth \
    --calldata $calldata
  echo "Function $function_name invoked."
  sleep 5
}

# Declare and deploy shard contract
declare_contract "sharding" "sharding_class_hash.txt"
deploy_contract "sharding_class_hash.txt" "sharding_contract_address.txt" "0x1f401c745d3dba9b9da11921d1fb006c96f571e9039a0ece3f3b0dc14f04c3d" #katana pre-deployed account address

# Declare and deploy test contract
declare_contract "test_contract" "test_contract_class_hash.txt"
deploy_contract "test_contract_class_hash.txt" "test_contract_address.txt" "$(cat sharding_contract_address.txt)"

rm sharding_class_hash.txt
rm test_contract_class_hash.txt

sncast invoke \
    --contract-address "$(cat sharding_contract_address.txt)" \
    --function "register_operator" \
    --fee-token eth \
    --calldata "$(cat test_contract_address.txt)"

TEST_CONTRACT_ADDRESS=$(cat test_contract_address.txt)
echo "Update snos_output.txt with new test contract address: $TEST_CONTRACT_ADDRESS"

cat > snos_output.txt.template << EOL
0x2 $TEST_CONTRACT_ADDRESS 0x0 0x1 0x1 0x7EBCC807B5C7E19F245995A55AED6F46F5F582F476A886B91B834B0DDF5854 0x5 0x1 $TEST_CONTRACT_ADDRESS 0x0 0x1 0x1 0x123 0x1 0x1
EOL

mv snos_output.txt.template snos_output.txt

echo "snos_output.txt was updated."