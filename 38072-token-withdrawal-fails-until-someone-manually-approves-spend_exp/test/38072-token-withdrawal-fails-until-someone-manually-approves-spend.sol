// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tadle — TokenManager.withdraw pulls from the capital pool with no allowance
    (CodeHawks, 38072). SYNTHETIC, cheatcode-free reduction.
    Root cause: the ERC20 branch calls _safe_transfer_from on the capital pool
    without the allowance check that _transfer already has, so every new token
    reverts until somebody manually calls capitalPool.approve. The blamed call
    is preserved verbatim below (@> VULN). */

error TransferFailed();

contract ERC20Mini {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract CapitalPool {
    function approve(address token) external {
        ERC20Mini(token).approve(msg.sender, type(uint256).max);
    }
}

contract TokenManager {
    ERC20Mini public token;
    address public capitalPoolAddr;
    mapping(address => mapping(address => mapping(uint8 => uint256))) public userTokenBalanceMap;

    constructor(ERC20Mini token_, address pool) {
        token = token_;
        capitalPoolAddr = pool;
    }

    function addTokenBalance(address account, address tokenAddress, uint8 kind, uint256 amount) external {
        userTokenBalanceMap[account][tokenAddress][kind] += amount;
    }

    function withdraw(address _tokenAddress, uint8 _tokenBalanceType) external {
        uint256 claimAbleAmount = userTokenBalanceMap[msg.sender][_tokenAddress][_tokenBalanceType]; // S4
        if (claimAbleAmount == 0) {
            return;
        }
        address pool = capitalPoolAddr;
        if (_tokenAddress == address(0)) {
            return;
        } else {
            _safe_transfer_from(_tokenAddress, pool, msg.sender, claimAbleAmount); // @> VULN: ERC20 withdraw skips the allowance check and capitalPool.approve // S5
            // FIX: if (IERC20(token).allowance(capitalPoolAddr, address(this)) == 0) ICapitalPool(capitalPoolAddr).approve(token);
        }
        userTokenBalanceMap[msg.sender][_tokenAddress][_tokenBalanceType] = 0;
    }

    function _safe_transfer_from(address tokenAddress, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            tokenAddress.call(abi.encodeWithSelector(ERC20Mini.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}

contract TokenManagerFixed {
    ERC20Mini public token;
    address public capitalPoolAddr;
    mapping(address => mapping(address => mapping(uint8 => uint256))) public userTokenBalanceMap;

    constructor(ERC20Mini token_, address pool) {
        token = token_;
        capitalPoolAddr = pool;
    }

    function addTokenBalance(address account, address tokenAddress, uint8 kind, uint256 amount) external {
        userTokenBalanceMap[account][tokenAddress][kind] += amount;
    }

    function withdraw(address _tokenAddress, uint8 kind) external {
        uint256 claimAbleAmount = userTokenBalanceMap[msg.sender][_tokenAddress][kind];
        require(claimAbleAmount > 0, "zero");
        if (ERC20Mini(_tokenAddress).allowance(capitalPoolAddr, address(this)) == 0) {
            CapitalPool(capitalPoolAddr).approve(_tokenAddress);
        }
        require(ERC20Mini(_tokenAddress).transferFrom(capitalPoolAddr, msg.sender, claimAbleAmount), "transfer");
        userTokenBalanceMap[msg.sender][_tokenAddress][kind] = 0;
    }
}

contract Maker {
    function tryWithdraw(TokenManager tm, address token) external returns (bool) {
        try tm.withdraw(token, 4) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    ERC20Mini public token; // nonce 1
    CapitalPool public pool; // nonce 2
    TokenManager public manager; // nonce 3 — vulnerable withdraw
    Maker public maker; // nonce 4
    bool public withdrew;
    bool public stuck;
    uint256 public constant REFUND = 1_200_000 ether;

    constructor() {
        token = new ERC20Mini();
        pool = new CapitalPool();
        manager = new TokenManager(token, address(pool));
        maker = new Maker();
        token.mint(address(pool), REFUND);
    }

    function run() external {
        manager.addTokenBalance(address(maker), address(token), 4, REFUND); // S1
        uint256 allowanceBefore = token.allowance(address(pool), address(manager)); // S2
        require(allowanceBefore == 0, "allowance preset");
        withdrew = maker.tryWithdraw(manager, address(token)); // S3
        stuck = token.balanceOf(address(maker)) == 0 && token.balanceOf(address(pool)) == REFUND;
        require(!withdrew && stuck, "not stuck"); // S6
    }
}
