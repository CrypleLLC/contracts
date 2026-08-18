// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
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

contract CounterfactualDeploymentTest is Test {
    EntryPoint internal entryPoint;
    P256AccountFactory internal factory;
    DeadManSwitch internal dms;

    uint256 internal constant OWNER_KEY = uint256(keccak256("counterfactual-owner-p256"));

    uint32 internal constant MIN_INACTIVITY = 5 minutes;
    uint32 internal constant MIN_CONTEST = 2 minutes;
    uint32 internal constant INACTIVITY = 10 minutes;
    uint32 internal constant CONTEST = 5 minutes;

    address internal constant CANONICAL_ENTRYPOINT = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;

    uint256 internal constant N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    uint256 internal constant HALF_N = 0x7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8;

    address internal bundler = makeAddr("bundler");

    function setUp() public {
        vm.warp(1_800_000_000);

        deployCodeTo("EntryPoint.sol:EntryPoint", CANONICAL_ENTRYPOINT);
        entryPoint = EntryPoint(payable(CANONICAL_ENTRYPOINT));

        factory = new P256AccountFactory();
        dms = new DeadManSwitch(MIN_INACTIVITY, MIN_CONTEST);
    }

    function test_OneUserOpDeploysTheAccountAndConfiguresTheSwitch() public {
        address sender = _counterfactualAddress();

        assertEq(sender.code.length, 0, "the account must not exist before the operation");

        vm.deal(sender, 1 ether);

        PackedUserOperation memory op = _buildDeployAndConfigure();
        op.signature = _sign(OWNER_KEY, entryPoint.getUserOpHash(op));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(bundler));

        assertGt(sender.code.length, 0, "initCode must have deployed the account");

        DeadManSwitch.Record memory record = dms.recordOf(sender);
        assertEq(uint8(record.status), uint8(DeadManSwitch.Status.Active), "the switch must be armed by the same op");
        assertEq(record.inactivityPeriod, INACTIVITY);
        assertEq(record.contestPeriod, CONTEST);
        assertEq(record.lastCheckIn, block.timestamp);
    }

    function test_TheDeployedAddressIsTheOneDerivedBeforeDeployment() public {
        address derived = _counterfactualAddress();

        vm.deal(derived, 1 ether);

        PackedUserOperation memory op = _buildDeployAndConfigure();
        op.signature = _sign(OWNER_KEY, entryPoint.getUserOpHash(op));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(bundler));

        (uint256 qx, uint256 qy) = vm.publicKeyP256(OWNER_KEY);
        (bytes32 storedQx, bytes32 storedQy) = P256Account(payable(derived)).signer();

        assertEq(storedQx, bytes32(qx), "the deployed account must be controlled by the signing key");
        assertEq(storedQy, bytes32(qy));
    }

    function test_TheSwitchSeesTheAccountAsTheCaller() public {
        address sender = _counterfactualAddress();
        vm.deal(sender, 1 ether);

        PackedUserOperation memory op = _buildDeployAndConfigure();
        op.signature = _sign(OWNER_KEY, entryPoint.getUserOpHash(op));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(bundler));

        assertEq(
            uint8(dms.statusOf(sender)),
            uint8(DeadManSwitch.Status.Active),
            "the record must be keyed by the smart account, never by a relayer"
        );
        assertEq(uint8(dms.statusOf(bundler)), uint8(DeadManSwitch.Status.Unconfigured));
    }

    function test_AForeignKeyCannotDeployIntoSomeoneElsesAddress() public {
        address sender = _counterfactualAddress();
        vm.deal(sender, 1 ether);

        PackedUserOperation memory op = _buildDeployAndConfigure();
        op.signature = _sign(uint256(keccak256("attacker-p256")), entryPoint.getUserOpHash(op));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        vm.prank(bundler, bundler);
        vm.expectRevert();
        entryPoint.handleOps(ops, payable(bundler));

        assertEq(sender.code.length, 0, "a failed validation must leave nothing deployed");
    }

    function _counterfactualAddress() private view returns (address) {
        (uint256 qx, uint256 qy) = vm.publicKeyP256(OWNER_KEY);

        return factory.getAddress(bytes32(qx), bytes32(qy), bytes32(0), 0, 0, bytes32(0));
    }

    function _initCode() private view returns (bytes memory) {
        (uint256 qx, uint256 qy) = vm.publicKeyP256(OWNER_KEY);

        return abi.encodePacked(
            address(factory),
            abi.encodeCall(P256AccountFactory.createAccount, (bytes32(qx), bytes32(qy), bytes32(0), 0, 0, bytes32(0)))
        );
    }

    function _buildDeployAndConfigure() private view returns (PackedUserOperation memory) {
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution({
            target: address(dms),
            value: 0,
            callData: abi.encodeCall(DeadManSwitch.configure, (INACTIVITY, CONTEST, bytes32(0), 0))
        });

        bytes32 mode = Mode.unwrap(
            ERC7579Utils.encodeMode(
                ERC7579Utils.CALLTYPE_BATCH,
                ERC7579Utils.EXECTYPE_DEFAULT,
                ModeSelector.wrap(0x00000000),
                ModePayload.wrap(0x00000000000000000000000000000000000000000000)
            )
        );

        address sender = _counterfactualAddress();

        return PackedUserOperation({
            sender: sender,
            nonce: entryPoint.getNonce(sender, 0),
            initCode: _initCode(),
            callData: abi.encodeCall(IERC7821.execute, (mode, ERC7579Utils.encodeBatch(batch))),
            accountGasLimits: bytes32((uint256(1_500_000) << 128) | uint256(1_000_000)),
            preVerificationGas: 200_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(1 gwei)),
            paymasterAndData: "",
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
