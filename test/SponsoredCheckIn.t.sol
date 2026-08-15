// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {TestPaymasterAcceptAll} from "account-abstraction/test/TestPaymasterAcceptAll.sol";
import {
    ERC7579Utils,
    Mode,
    CallType,
    ExecType,
    ModeSelector,
    ModePayload
} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IERC7821} from "@openzeppelin/contracts/interfaces/draft-IERC7821.sol";
import {P256Account} from "p256-account/P256Account.sol";
import {P256AccountFactory} from "p256-account/P256AccountFactory.sol";
import {DeadManSwitch} from "../src/DeadManSwitch.sol";

// The product's central claim, against the real chain: no wallet, no extension,
// no ETH. A user's account holding zero wei checks in, and a paymaster pays.
//
// Runs against live Arbitrum Sepolia rather than a local EntryPoint, so the
// EntryPoint, its version and its accounting are the deployed ones and not a
// local copy that happens to agree. Skipped when ARBITRUM_SEPOLIA_RPC_URL is
// unset, so it never breaks a machine or a CI job without an endpoint.
contract SponsoredCheckInTest is Test {
    IEntryPoint internal constant ENTRYPOINT_V09 = IEntryPoint(0x433709009B8330FDa32311DF1C2AFA402eD8D009);

    P256AccountFactory internal factory;
    P256Account internal account;
    DeadManSwitch internal dms;
    TestPaymasterAcceptAll internal paymaster;

    uint256 internal constant PEDRO_KEY = uint256(keccak256("pedro-seed-p256"));

    uint32 internal constant MIN_INACTIVITY = 5 minutes;
    uint32 internal constant MIN_CONTEST = 2 minutes;
    uint32 internal constant INACTIVITY = 180 days;
    uint32 internal constant CONTEST = 7 days;

    uint256 internal constant N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    uint256 internal constant HALF_N = 0x7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8;

    address internal bundler = makeAddr("bundler");
    address internal sponsor = makeAddr("sponsor");

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        factory = new P256AccountFactory();
        dms = new DeadManSwitch(MIN_INACTIVITY, MIN_CONTEST);

        (uint256 qx, uint256 qy) = vm.publicKeyP256(PEDRO_KEY);
        account = P256Account(payable(factory.createAccount(bytes32(qx), bytes32(qy), bytes32(0), 0, 0, bytes32(0))));

        vm.deal(sponsor, 1 ether);
        vm.startPrank(sponsor, sponsor);
        paymaster = new TestPaymasterAcceptAll(ENTRYPOINT_V09);
        paymaster.deposit{value: 0.5 ether}();
        vm.stopPrank();
    }

    function test_AZeroBalanceAccountChecksInWithoutEverHoldingEth() public {
        _skipWithoutFork();

        assertEq(address(account).balance, 0, "the account must start with no ETH");
        assertEq(ENTRYPOINT_V09.balanceOf(address(account)), 0, "and no EntryPoint deposit of its own");

        uint256 paymasterBefore = ENTRYPOINT_V09.balanceOf(address(paymaster));

        _sendSponsored(abi.encodeCall(DeadManSwitch.configure, (INACTIVITY, CONTEST, bytes32(0), 0)));

        DeadManSwitch.Record memory record = dms.recordOf(address(account));
        assertEq(uint8(record.status), uint8(DeadManSwitch.Status.Active));
        assertEq(record.lastCheckIn, uint64(block.timestamp));

        vm.warp(block.timestamp + 90 days);
        _sendSponsored(abi.encodeCall(DeadManSwitch.checkIn, ()));
        assertEq(dms.recordOf(address(account)).lastCheckIn, uint64(block.timestamp));

        assertEq(address(account).balance, 0, "the account must never have needed ETH");
        assertEq(ENTRYPOINT_V09.balanceOf(address(account)), 0, "nor a deposit");
        assertLt(
            ENTRYPOINT_V09.balanceOf(address(paymaster)), paymasterBefore, "the paymaster must be the one that paid"
        );
    }

    // The fallback that keeps sponsorship off the safety path: if nobody
    // sponsors, an account holding its own ETH still checks in unaided.
    function test_AnUnsponsoredAccountCanStillCheckInFromItsOwnDeposit() public {
        _skipWithoutFork();

        vm.deal(address(account), 1 ether);
        vm.prank(address(account));
        ENTRYPOINT_V09.depositTo{value: 0.5 ether}(address(account));

        _send(abi.encodeCall(DeadManSwitch.configure, (INACTIVITY, CONTEST, bytes32(0), 0)), "");

        assertEq(uint8(dms.statusOf(address(account))), uint8(DeadManSwitch.Status.Active));
        assertLt(ENTRYPOINT_V09.balanceOf(address(account)), 0.5 ether, "the account paid for itself");
    }

    // The EntryPoint the account hardcodes is the one actually deployed here,
    // and it is the one this repository vendors. Pins the pair against drift.
    function test_TheHardcodedEntryPointIsDeployedAndIsTheAccountsOwn() public {
        _skipWithoutFork();

        assertGt(address(ENTRYPOINT_V09).code.length, 0, "EntryPoint v0.9 must exist on this chain");
        assertEq(address(account.entryPoint()), address(ENTRYPOINT_V09));
    }

    function _skipWithoutFork() private {
        vm.skip(address(dms) == address(0), "ARBITRUM_SEPOLIA_RPC_URL unset");
    }

    function _sendSponsored(bytes memory innerCall) private {
        bytes memory paymasterAndData = abi.encodePacked(address(paymaster), uint128(500_000), uint128(100_000));
        _send(innerCall, paymasterAndData);
    }

    function _send(bytes memory innerCall, bytes memory paymasterAndData) private {
        PackedUserOperation memory op = _build(innerCall, paymasterAndData);
        op.signature = _sign(PEDRO_KEY, ENTRYPOINT_V09.getUserOpHash(op));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.prank(bundler, bundler);
        ENTRYPOINT_V09.handleOps(ops, payable(bundler));
    }

    function _build(bytes memory innerCall, bytes memory paymasterAndData)
        private
        view
        returns (PackedUserOperation memory)
    {
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution({target: address(dms), value: 0, callData: innerCall});

        bytes32 mode = Mode.unwrap(
            ERC7579Utils.encodeMode(
                ERC7579Utils.CALLTYPE_BATCH,
                ERC7579Utils.EXECTYPE_DEFAULT,
                ModeSelector.wrap(0x00000000),
                ModePayload.wrap(0x00000000000000000000000000000000000000000000)
            )
        );

        return PackedUserOperation({
            sender: address(account),
            nonce: ENTRYPOINT_V09.getNonce(address(account), 0),
            initCode: "",
            callData: abi.encodeCall(IERC7821.execute, (mode, ERC7579Utils.encodeBatch(batch))),
            accountGasLimits: bytes32((uint256(1_000_000) << 128) | uint256(1_000_000)),
            preVerificationGas: 100_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(1 gwei)),
            paymasterAndData: paymasterAndData,
            signature: ""
        });
    }

    function _sign(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (bytes32 r, bytes32 s) = vm.signP256(key, digest);
        if (uint256(s) > HALF_N) {
            s = bytes32(N - uint256(s));
        }
        return abi.encodePacked(r, s);
    }
}
