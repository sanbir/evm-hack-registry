// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  QuantAMM — UpliftOnlyExample.onAfterRemoveLiquidity (Cyfrin, 2024-12).
    maxAmountsIn is exitFee.mulDown(adminFeePercent). The vault's proportional
    add rounds the required amount up, so amountInRaw is 1 wei above
    maxAmountsIn and addLiquidity reverts AmountInAboveMax. The user's
    1000 tokens stay in the vault. The control adds a 1 wei buffer and
    the withdrawal completes.
*/

contract Token {
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct AddLiquidityParams {
    address pool;
    address to;
    uint256[] maxAmountsIn;
    uint256 minBptAmountOut;
    uint8 kind;
    bytes userData;
}

contract Vault {
    uint8 public constant PROPORTIONAL = 0;
    Token public token;
    address public pool;
    uint256 public totalSupply;
    uint256 public balance;
    address public admin;

    error AmountInAboveMax(address token, uint256 amountInRaw, uint256 maxAmountIn);

    constructor(Token _token, address _pool, address _admin) {
        token = _token;
        pool = _pool;
        admin = _admin;
        totalSupply = 1000 ether;
        balance = 1000 ether;
    }

    function addLiquidity(AddLiquidityParams calldata params) external {
        require(params.kind == PROPORTIONAL, "kind");
        uint256 amountInRaw = (balance * params.minBptAmountOut) / totalSupply;
        uint256 maxIn = params.maxAmountsIn[0];
        if (amountInRaw > maxIn) {
            revert AmountInAboveMax(address(token), amountInRaw, maxIn);
        }
        balance += amountInRaw;
        totalSupply += params.minBptAmountOut;
    }

    function getQuantAMMAdmin() external view returns (address) {
        return admin;
    }

    function pay(address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

contract UpliftOnlyExample {
    uint8 public constant PROPORTIONAL = 0;
    Vault public vault;
    Token public token;
    address public pool;
    uint256 public adminFeePercent = 0.5 ether;
    bool public lastRemoveReverted;
    uint256 public lastAmountInRaw;

    struct AfterRemoveLiquidityData {
        address pool;
        uint256 feeAmount;
        uint256 adminFeePercent;
        uint256[] accruedQuantAMMFees;
    }

    constructor(Vault _vault, Token _token, address _pool) {
        vault = _vault;
        token = _token;
        pool = _pool;
    }

    function mulDown(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * b) / 1e18;
    }

    function onAfterRemoveLiquidity(address user, uint256) external returns (bool, uint256[] memory adjusted) {
        AfterRemoveLiquidityData memory localData;
        localData.pool = pool;
        localData.adminFeePercent = adminFeePercent;
        localData.feeAmount = 4 ether;
        uint256 exitFee = mulDown(4, adminFeePercent);
        localData.accruedQuantAMMFees = new uint256[](1);
        localData.accruedQuantAMMFees[0] = mulDown(exitFee, localData.adminFeePercent);
        adjusted = new uint256[](1);
        adjusted[0] = 1000 ether;
        user;
        if (localData.adminFeePercent > 0) {
            // @> VULN: maxAmountsIn is mulDown of the admin fee, 1 wei under the vault's proportional amountInRaw
            vault.addLiquidity(
                AddLiquidityParams({
                    pool: localData.pool,
                    to: vault.getQuantAMMAdmin(),
                    maxAmountsIn: localData.accruedQuantAMMFees,
                    minBptAmountOut: mulDown(localData.feeAmount, localData.adminFeePercent) / 1e18,
                    kind: PROPORTIONAL,
                    userData: bytes("")
                })
            );
        }
        return (true, adjusted);
    }

    function removeLiquidity(address user, uint256 bptIn) external returns (bool paid) {
        try this.onAfterRemoveLiquidity(user, bptIn) returns (bool, uint256[] memory) {
            token.transfer(user, bptIn);
            paid = true;
            lastRemoveReverted = false;
        } catch {
            paid = false;
            lastRemoveReverted = true;
        }
    }
}

contract UpliftOnlyExampleFixed {
    uint8 public constant PROPORTIONAL = 0;
    Vault public vault;
    Token public token;
    address public pool;
    uint256 public adminFeePercent = 0.5 ether;

    constructor(Vault _vault, Token _token, address _pool) {
        vault = _vault;
        token = _token;
        pool = _pool;
    }

    function mulDown(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * b) / 1e18;
    }

    function removeLiquidity(address user, uint256 bptIn) external returns (uint256 paid) {
        uint256 feeAmount = 4 ether;
        uint256 exitFee = mulDown(4, adminFeePercent);
        uint256[] memory maxIn = new uint256[](1);
        maxIn[0] = mulDown(exitFee, adminFeePercent) + 1;
        vault.addLiquidity(
            AddLiquidityParams({
                pool: pool,
                to: vault.getQuantAMMAdmin(),
                maxAmountsIn: maxIn,
                minBptAmountOut: mulDown(feeAmount, adminFeePercent) / 1e18,
                kind: PROPORTIONAL,
                userData: bytes("")
            })
        );
        paid = bptIn - 2;
        vault.pay(user, paid);
    }
}

contract Exploit {
    address public constant USER = address(uint160(0xA11CE));
    address public constant ADMIN = address(uint160(0xAD11));
    address public constant POOL = address(uint160(0xB001));
    uint256 public constant DEPOSIT = 1000 ether;

    Token public token;
    Vault public vault;
    UpliftOnlyExample public hook;
    bool public removed;
    uint256 public maxIn;
    uint256 public amountInRaw;

    constructor() {
        token = new Token();
        vault = new Vault(token, POOL, ADMIN);
        hook = new UpliftOnlyExample(vault, token, POOL);
    }

    function run() external {
        token.mint(address(vault), DEPOSIT);
        uint256 exitFee = hook.mulDown(4, hook.adminFeePercent());
        maxIn = hook.mulDown(exitFee, hook.adminFeePercent());
        amountInRaw = (vault.balance() * 2) / vault.totalSupply();
        removed = hook.removeLiquidity(USER, DEPOSIT);
        require(maxIn + 1 == amountInRaw, "one wei");
        require(!removed, "removed");
        require(hook.lastRemoveReverted(), "reverted");
        require(token.balanceOf(address(vault)) == DEPOSIT, "locked");
        require(token.balanceOf(USER) == 0, "user");
    }
}
