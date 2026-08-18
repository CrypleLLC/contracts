#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
import urllib.request

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

def load_dotenv() -> None:
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
    if not os.path.exists(path):
        return

    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue

            name, _, value = line.partition("=")
            os.environ.setdefault(name.strip(), value.strip().strip("\"'"))


load_dotenv()

CHAIN_ID = 421614

RPC_URL = os.environ.get("ARBITRUM_SEPOLIA_RPC_URL", "https://sepolia-rollup.arbitrum.io/rpc")
BUNDLER_URL = os.environ.get("BUNDLER_URL", f"https://public.pimlico.io/v2/{CHAIN_ID}/rpc")

PAYMASTER_API_KEY = os.environ.get("PIMLICO_API_KEY", "")
SPONSORSHIP_POLICY_ID = os.environ.get("PIMLICO_SPONSORSHIP_POLICY_ID", "")

ENTRY_POINT = "0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108"
FACTORY = "0x67b0cfF584B13E9275Ffc2cA6EBb2e94546D595b"
DEAD_MAN_SWITCH = "0x6951a65CDc706A2D23E1015d35B8353F18A569a9"

INACTIVITY_PERIOD = 600
CONTEST_PERIOD = 300

CURVE_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
HALF_ORDER = CURVE_ORDER // 2

ERC7821_SINGLE_BATCH_MODE = "0x01000000000000000000000000000000000000000000000000000000000000000"[:66]

DUMMY_SIGNATURE = "0x" + "11" * 64

VERIFICATION_GAS_LIMIT = 2_000_000
CALL_GAS_LIMIT = 1_000_000
PRE_VERIFICATION_GAS = 300_000


def cast(*args: str) -> str:
    result = subprocess.run(
        ["cast", *args, "--rpc-url", RPC_URL],
        capture_output=True,
        text=True,
        timeout=90,
    )
    if result.returncode != 0:
        raise RuntimeError(f"cast {' '.join(args)} failed: {result.stderr.strip()}")

    return result.stdout.strip()


def cast_local(*args: str) -> str:
    result = subprocess.run(["cast", *args], capture_output=True, text=True, timeout=90)
    if result.returncode != 0:
        raise RuntimeError(f"cast {' '.join(args)} failed: {result.stderr.strip()}")

    return result.stdout.strip()


def owner_key() -> ec.EllipticCurvePrivateKey:
    scalar = int(os.environ.get("OWNER_P256_KEY", "0x" + "42" * 32), 16)

    return ec.derive_private_key(scalar, ec.SECP256R1())


def public_coordinates(key: ec.EllipticCurvePrivateKey) -> tuple[str, str]:
    numbers = key.public_key().public_numbers()

    return f"0x{numbers.x:064x}", f"0x{numbers.y:064x}"


def sign_low_s(key: ec.EllipticCurvePrivateKey, digest_hex: str) -> str:
    digest = bytes.fromhex(digest_hex[2:])
    der = key.sign(digest, ec.ECDSA(utils.Prehashed(hashes.SHA256())))
    r, s = utils.decode_dss_signature(der)
    if s > HALF_ORDER:
        s = CURVE_ORDER - s

    return f"0x{r:064x}{s:064x}"


def counterfactual_address(qx: str, qy: str) -> str:
    raw = cast(
        "call",
        FACTORY,
        "getAddress(bytes32,bytes32,bytes32,uint32,uint64,bytes32)(address)",
        qx,
        qy,
        "0x" + "00" * 32,
        "0",
        "0",
        "0x" + "00" * 32,
    )

    return raw.split()[0]


def factory_data(qx: str, qy: str) -> str:
    return cast_local(
        "calldata",
        "createAccount(bytes32,bytes32,bytes32,uint32,uint64,bytes32)",
        qx,
        qy,
        "0x" + "00" * 32,
        "0",
        "0",
        "0x" + "00" * 32,
    )


def switch_call_data(inner: str) -> str:
    execution_data = cast_local(
        "abi-encode",
        "f((address,uint256,bytes)[])",
        f"[({DEAD_MAN_SWITCH},0,{inner})]",
    )

    return cast_local("calldata", "execute(bytes32,bytes)", ERC7821_SINGLE_BATCH_MODE, execution_data)


def configure_call_data() -> str:
    return switch_call_data(
        cast_local(
            "calldata",
            "configure(uint32,uint32,bytes32,uint8)",
            str(INACTIVITY_PERIOD),
            str(CONTEST_PERIOD),
            "0x" + "00" * 32,
            "0",
        )
    )


def check_in_call_data() -> str:
    return switch_call_data(cast_local("calldata", "checkIn()"))


def is_deployed(sender: str) -> bool:
    return rpc(RPC_URL, "eth_getCode", [sender, "latest"]).get("result", "0x") != "0x"


def is_configured(sender: str) -> bool:
    return int(cast("call", DEAD_MAN_SWITCH, "statusOf(address)(uint8)", sender).split()[0]) != 0


def packed_gas(high: int, low: int) -> str:
    return f"0x{high:032x}{low:032x}"


def paymaster_url() -> str:
    if not PAYMASTER_API_KEY:
        return BUNDLER_URL

    return f"https://api.pimlico.io/v2/{CHAIN_ID}/rpc?apikey={PAYMASTER_API_KEY}"


def redact(text: str) -> str:
    return text.replace(PAYMASTER_API_KEY, "<apikey>") if PAYMASTER_API_KEY else text


def pack_paymaster(fields: dict) -> str:
    if not fields.get("paymaster"):
        return "0x"

    verification = int(fields.get("paymasterVerificationGasLimit", "0x0"), 16)
    post_op = int(fields.get("paymasterPostOpGasLimit", "0x0"), 16)
    data = fields.get("paymasterData", "0x") or "0x"

    return fields["paymaster"].lower() + f"{verification:032x}{post_op:032x}" + data[2:]


def user_op_hash(
    sender: str,
    nonce: int,
    init_code: str,
    call_data: str,
    signature: str,
    paymaster_and_data: str = "0x",
) -> str:
    packed = (
        f"({sender},{nonce},{init_code},{call_data},"
        f"{packed_gas(VERIFICATION_GAS_LIMIT, CALL_GAS_LIMIT)},{PRE_VERIFICATION_GAS},"
        f"{packed_gas(GAS_FEES[0], GAS_FEES[1])},{paymaster_and_data},{signature})"
    )
    raw = cast(
        "call",
        ENTRY_POINT,
        "getUserOpHash((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes))(bytes32)",
        packed,
    )

    return raw.split()[0]


def rpc(url: str, method: str, params: list) -> dict:
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "cryple-task47/1.0"},
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as failure:
        body = failure.read().decode(errors="replace")
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {"error": {"code": failure.code, "message": body[:500]}}


def required_prefund() -> int:
    return (VERIFICATION_GAS_LIMIT + CALL_GAS_LIMIT + PRE_VERIFICATION_GAS) * GAS_FEES[1]


def wait_for_receipt(user_op_hash: str, attempts: int = 40, delay: int = 3) -> dict | None:
    for _ in range(attempts):
        answer = rpc(BUNDLER_URL, "eth_getUserOperationReceipt", [user_op_hash])
        receipt = answer.get("result")
        if receipt:
            return receipt
        time.sleep(delay)

    return None


def build(signature: str) -> tuple[dict, str, str]:
    key = owner_key()
    qx, qy = public_coordinates(key)
    sender = counterfactual_address(qx, qy)

    data = factory_data(qx, qy)
    init_code = FACTORY.lower() + data[2:]
    call_data = configure_call_data()

    nonce = int(cast("call", ENTRY_POINT, "getNonce(address,uint192)(uint256)", sender, "0").split()[0])

    op = {
        "sender": sender,
        "nonce": hex(nonce),
        "factory": FACTORY,
        "factoryData": data,
        "callData": call_data,
        "callGasLimit": hex(CALL_GAS_LIMIT),
        "verificationGasLimit": hex(VERIFICATION_GAS_LIMIT),
        "preVerificationGas": hex(PRE_VERIFICATION_GAS),
        "maxFeePerGas": hex(GAS_FEES[1]),
        "maxPriorityFeePerGas": hex(GAS_FEES[0]),
        "signature": signature,
    }

    return op, init_code, call_data


def sponsor_context() -> dict:
    return {"sponsorshipPolicyId": SPONSORSHIP_POLICY_ID} if SPONSORSHIP_POLICY_ID else {}


def request_paymaster(method: str, op: dict) -> dict | None:
    answer = rpc(paymaster_url(), method, [op, ENTRY_POINT, hex(CHAIN_ID), sponsor_context()])
    if "error" in answer:
        print(f"{method}: {redact(json.dumps(answer['error']))}")

        return None

    return answer["result"]


def build_sponsored(key, sender: str) -> tuple[dict, str, str] | None:
    deployed = is_deployed(sender)
    check_in = deployed and is_configured(sender)
    call_data = check_in_call_data() if check_in else configure_call_data()
    nonce = int(cast("call", ENTRY_POINT, "getNonce(address,uint192)(uint256)", sender, "0").split()[0])

    op = {
        "sender": sender,
        "nonce": hex(nonce),
        "callData": call_data,
        "callGasLimit": hex(CALL_GAS_LIMIT),
        "verificationGasLimit": hex(VERIFICATION_GAS_LIMIT),
        "preVerificationGas": hex(PRE_VERIFICATION_GAS),
        "maxFeePerGas": hex(GAS_FEES[1]),
        "maxPriorityFeePerGas": hex(GAS_FEES[0]),
        "signature": DUMMY_SIGNATURE,
    }

    init_code = "0x"
    if not deployed:
        qx, qy = public_coordinates(key)
        data = factory_data(qx, qy)
        op["factory"] = FACTORY
        op["factoryData"] = data
        init_code = FACTORY.lower() + data[2:]

    inner = "checkIn()" if check_in else "configure()"
    print(f"operation        {inner if deployed else 'deploy + ' + inner}")

    stub = request_paymaster("pm_getPaymasterStubData", op)
    if stub is None:
        return None

    op.update({field: stub[field] for field in ("paymaster", "paymasterData") if field in stub})
    for field in ("paymasterVerificationGasLimit", "paymasterPostOpGasLimit"):
        op[field] = stub.get(field, hex(200_000))

    final = request_paymaster("pm_getPaymasterData", op) if not stub.get("isFinal") else stub
    if final is None:
        return None

    op.update({field: final[field] for field in ("paymaster", "paymasterData") if field in final})
    print(f"paymaster        {op.get('paymaster')}")

    return op, init_code, call_data


def report_receipt(user_op_hash: str, sender: str) -> int:
    print(f"\nwaiting for receipt of {user_op_hash} ...")
    receipt = wait_for_receipt(user_op_hash)
    if receipt is None:
        print("VERDICT: no receipt after the polling window; the operation is still pending.")

        return 1

    print(json.dumps(receipt, indent=2))

    code = rpc(RPC_URL, "eth_getCode", [sender, "latest"]).get("result", "0x")
    record = cast(
        "call",
        DEAD_MAN_SWITCH,
        "recordOf(address)((uint64,uint32,uint32,bytes32,uint8,uint8,uint64))",
        sender,
    )
    print(f"\nsender deployed  {code != '0x'} ({len(code) // 2 - 1} bytes of code)")
    print(f"switch record    {record}")

    if not receipt.get("success"):
        print("\nVERDICT: the operation was mined but reverted inside the call phase.")

        return 1

    print("\nVERDICT: one userOp carrying initCode deployed the account through a hosted")
    print("bundler and executed configure() on the live DeadManSwitch.")

    return 0


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "estimate"

    key = owner_key()
    qx, qy = public_coordinates(key)
    op, init_code, call_data = build(DUMMY_SIGNATURE)
    sender = op["sender"]

    print(f"bundler          {BUNDLER_URL}")
    print(f"entry point      {ENTRY_POINT}")
    print(f"factory          {FACTORY}  (stake checked below)")
    print(f"owner qx         {qx}")
    print(f"counterfactual   {sender}")

    code = rpc(RPC_URL, "eth_getCode", [sender, "latest"]).get("result", "0x")
    balance = int(rpc(RPC_URL, "eth_getBalance", [sender, "latest"]).get("result", "0x0"), 16)
    prefund = required_prefund()
    print(f"sender deployed  {code != '0x'}")
    print(f"sender balance   {balance} wei ({balance / 10**18:.7f} ETH)")
    print(f"prefund needed   {prefund} wei ({prefund / 10**18:.7f} ETH)")

    deposit = cast(
        "call",
        ENTRY_POINT,
        "getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))",
        FACTORY,
    )
    print(f"factory deposit  {deposit}")

    supported = rpc(BUNDLER_URL, "eth_supportedEntryPoints", []).get("result", [])
    print(f"ep supported     {ENTRY_POINT.lower() in [e.lower() for e in supported]}")
    print()

    if mode == "estimate":
        overrides = {sender: {"balance": hex(10**18)}}
        answer = rpc(BUNDLER_URL, "eth_estimateUserOperationGas", [op, ENTRY_POINT, overrides])
        print(json.dumps(answer, indent=2))

        if "error" in answer:
            print("\nVERDICT: the bundler refused the operation. Read the error above:")
            print("  an AA1x / factory / opcode / storage code means ERC-7562 rejected the factory")
            print("  an AA2x code means validation was reached and the factory was accepted")

            return 1

        print("\nVERDICT: the bundler simulated a userOp carrying initCode for this factory")
        print("and returned gas estimates, so ERC-7562 validation accepted the unstaked factory.")

        return 0

    if mode == "simulate":
        digest = user_op_hash(sender, int(op["nonce"], 16), init_code, call_data, "0x")
        signature = sign_low_s(key, digest)
        print(f"userOpHash       {digest}")

        packed = (
            f"[({sender},{int(op['nonce'], 16)},{init_code},{call_data},"
            f"{packed_gas(VERIFICATION_GAS_LIMIT, CALL_GAS_LIMIT)},{PRE_VERIFICATION_GAS},"
            f"{packed_gas(GAS_FEES[0], GAS_FEES[1])},0x,{signature})]"
        )
        data = cast_local(
            "calldata",
            "handleOps((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes)[],address)",
            packed,
            BENEFICIARY,
        )

        answer = rpc(
            RPC_URL,
            "eth_call",
            [
                {"from": BENEFICIARY, "to": ENTRY_POINT, "data": data, "gas": hex(8_000_000)},
                "latest",
                {sender: {"balance": hex(10**18)}},
            ],
        )
        print(json.dumps(answer, indent=2))

        if "error" in answer:
            print("\nVERDICT: handleOps reverted. AA24 means the P-256 signature was rejected;")
            print("AA13/AA14 mean the factory failed; anything else is in the configure() call.")

            return 1

        print("\nVERDICT: the whole operation simulates clean against the live deployment --")
        print("factory deploys the account, the P-256 signature verifies through RIP-7212,")
        print("and configure() executes. Only the prefund is missing for a real send.")

        return 0

    if mode == "send":
        if balance < prefund:
            print(f"ABORT: fund {sender} with at least {prefund} wei before sending.")

            return 1

        digest = user_op_hash(sender, int(op["nonce"], 16), init_code, call_data, "0x")
        op["signature"] = sign_low_s(key, digest)
        print(f"userOpHash       {digest}")
        print(f"signature        {op['signature']}")

        answer = rpc(BUNDLER_URL, "eth_sendUserOperation", [op, ENTRY_POINT])
        print(json.dumps(answer, indent=2))

        if "error" in answer:
            return 1

        return report_receipt(answer["result"], sender)

    if mode == "sponsor":
        if not PAYMASTER_API_KEY or not SPONSORSHIP_POLICY_ID:
            print("ABORT: sponsorship needs PIMLICO_API_KEY and PIMLICO_SPONSORSHIP_POLICY_ID.")
            print("The public endpoint routes pm_* but carries no policy, so it answers")
            print("'Sponsorship policy ID is required for this API key'.")

            return 2

        built = build_sponsored(key, sender)
        if built is None:
            print("\nVERDICT: the paymaster declined to sponsor. A policy that does not list")
            print(f"{DEAD_MAN_SWITCH} as an allowed target is the first thing to check.")

            return 1

        sponsored, init_code, call_data = built
        packed_paymaster = pack_paymaster(sponsored)
        digest = user_op_hash(
            sender,
            int(sponsored["nonce"], 16),
            init_code,
            call_data,
            "0x",
            packed_paymaster,
        )
        sponsored["signature"] = sign_low_s(key, digest)
        print(f"userOpHash       {digest}")

        answer = rpc(BUNDLER_URL, "eth_sendUserOperation", [sponsored, ENTRY_POINT])
        print(redact(json.dumps(answer, indent=2)))

        if "error" in answer:
            return 1

        before = balance
        code = report_receipt(answer["result"], sender)
        after = int(rpc(RPC_URL, "eth_getBalance", [sender, "latest"]).get("result", "0x0"), 16)
        deposit = int(cast("call", ENTRY_POINT, "balanceOf(address)(uint256)", sender).split()[0])
        print(f"\nsender balance   {before} -> {after} wei")
        print(f"sender deposit   {deposit} wei")

        if after == before and deposit == 0:
            print("VERDICT: the account paid nothing and holds no deposit -- the paymaster paid.")
        else:
            print("VERDICT: the operation landed but the account's own funds moved. Not sponsored.")

            return 1

        return code

    if mode == "receipt":
        if len(sys.argv) < 3:
            print("usage: bundler_userop.py receipt <userOpHash>")

            return 2

        return report_receipt(sys.argv[2], sender)

    print(f"unknown mode {mode!r}; use estimate, simulate, send, sponsor or receipt")

    return 2


BENEFICIARY = "0x000000000000000000000000000000000000dEaD"

GAS_FEES = (100_000_000, 200_000_000)

if __name__ == "__main__":
    sys.exit(main())
