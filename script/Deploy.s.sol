// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeadManSwitch} from "../src/DeadManSwitch.sol";
import {ProofRegistry} from "../src/ProofRegistry.sol";

// Deploys the two product contracts.
//
// The minimum periods are a deployment constant, not a code constant: a testnet
// deployment must be able to exercise the whole lifecycle in minutes, while a
// production deployment protects users from configuring a switch that fires on
// them during a holiday. The values in force are printed and MUST be copied into
// the deployment record in .docs/onchain-architecture.md.
//
// Environment: see .env.example. The rpc-url is the alias declared in
// foundry.toml, which resolves ARBITRUM_SEPOLIA_RPC_URL and carries the
// Arbiscan key and chain id that --verify needs.
//
//   forge script script/Deploy.s.sol \
//     --rpc-url arbitrum_sepolia \
//     --account $DEPLOYER_ACCOUNT \
//     --broadcast --verify
contract Deploy is Script {
    uint32 public constant MAINNET_MIN_INACTIVITY = 30 days;
    uint32 public constant MAINNET_MIN_CONTEST = 7 days;

    uint32 public constant TESTNET_MIN_INACTIVITY = 5 minutes;
    uint32 public constant TESTNET_MIN_CONTEST = 2 minutes;

    function run() external returns (DeadManSwitch dms, ProofRegistry registry) {
        bool production = vm.envOr("PRODUCTION", false);

        uint32 minInactivity = uint32(
            vm.envOr("MIN_INACTIVITY_SECONDS", uint256(production ? MAINNET_MIN_INACTIVITY : TESTNET_MIN_INACTIVITY))
        );
        uint32 minContest =
            uint32(vm.envOr("MIN_CONTEST_SECONDS", uint256(production ? MAINNET_MIN_CONTEST : TESTNET_MIN_CONTEST)));

        require(minInactivity > 0 && minContest > 0, "minimum periods must be non-zero");
        if (production) {
            require(minInactivity >= MAINNET_MIN_INACTIVITY, "production inactivity floor too low");
            require(minContest >= MAINNET_MIN_CONTEST, "production contest floor too low");
        }

        vm.startBroadcast();
        dms = new DeadManSwitch(minInactivity, minContest);
        registry = new ProofRegistry();
        vm.stopBroadcast();

        console.log("chain id                ", block.chainid);
        console.log("production              ", production);
        console.log("minInactivityPeriod (s) ", minInactivity);
        console.log("minContestPeriod    (s) ", minContest);
        console.log("DeadManSwitch           ", address(dms));
        console.log("ProofRegistry           ", address(registry));
        console.log("");
        console.log("Record these in .docs/onchain-architecture.md (Deployment Record),");
        console.log("together with the commit hash, compiler settings and Arbiscan links.");
    }
}
