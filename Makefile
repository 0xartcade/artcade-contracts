# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

#####################################
### FORMAT & LINT
#####################################
fmt:
	forge fmt

slither:
	poetry run slither .

install-pre-commit:
	poetry run pre-commit install

#####################################
### MODULES
#####################################
remove:
	rm -rf dependencies

install:
	forge soldeer install

update: remove install
	
#####################################
### BUILD
#####################################
clean:
	forge fmt && forge clean

build:
	forge build --evm-version paris

clean_build: clean build

docs: clean_build
	forge doc --build

#####################################
### TESTS
#####################################
tests: build
	forge test

gas-tests: build
	forge test --gas-report

cov-tests: build
	forge coverage --no-match-coverage "(script|test|Foo|Bar)"

fuzz-tests: build
	forge test --fuzz-runs 10000

#####################################
### DEPLOY TESTNET
#####################################

deploy-artcade-testnet: build
	forge script script/Deploy.s.sol:DeployArtcade --evm-version paris --rpc-url shape_sepolia --ledger --sender ${SENDER} --broadcast
	forge verify-contract $$(cat out.txt) src/Artcade.sol:Artcade --verifier blockscout --verifier-url https://explorer-sepolia.shape.network/api --watch --constructor-args ${CONSTRUCTOR_ARGS}
	@bash print_and_clean.sh

deploy-game-testnet: build
	forge script script/Deploy.s.sol:DeployGame --evm-version paris --rpc-url shape_sepolia --ledger --sender ${SENDER} --broadcast
	forge verify-contract $$(cat out.txt) src/Game.sol:Game --verifier blockscout --verifier-url https://explorer-sepolia.shape.network/api --watch --constructor-args ${CONSTRUCTOR_ARGS}
	@bash print_and_clean.sh

#####################################
### DEPLOY MAINNET
#####################################

deploy-artcade-mainnet: build
	forge script script/Deploy.s.sol:DeployArtcade --evm-version paris --rpc-url shape --ledger --sender ${SENDER} --broadcast
	forge verify-contract $$(cat out.txt) src/Artcade.sol:Artcade --verifier blockscout --verifier-url https://shapescan.xyz/api --watch --constructor-args ${CONSTRUCTOR_ARGS}
	@bash print_and_clean.sh

deploy-game-mainnet: build
	forge script script/Deploy.s.sol:DeployGame --evm-version paris --rpc-url shape --ledger --sender ${SENDER} --broadcast
	forge verify-contract $$(cat out.txt) src/Game.sol:Game --verifier blockscout --verifier-url https://shapescan.xyz/api --watch --constructor-args ${CONSTRUCTOR_ARGS}
	@bash print_and_clean.sh