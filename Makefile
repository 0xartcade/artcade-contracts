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
	rm -rf lib

install:
	forge install foundry-rs/forge-std --no-git
	forge install Transient-Labs/tl-creator-contracts@3.3.0 --no-git

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

