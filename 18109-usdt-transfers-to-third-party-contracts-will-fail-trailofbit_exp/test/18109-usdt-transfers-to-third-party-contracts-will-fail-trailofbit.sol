// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Meson — release to a third-party contract calls increaseAllowance
    (Trail of Bits, TOB Meson, Oct 2022, MesonHelpers.sol).
    SYNTHETIC, cheatcode-free reduction.
    The audited call is a high-level IERC20Minimal.increaseAllowance, which
    ABI-decodes a bool. USDT does not implement that method and its transfer
    returns no bool, so the release reverts and N stays in the pool.
    A token whose increaseAllowance returns true lets the contract wallet
    pull N to the beneficiary. */

interface IERC20Minimal {
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface ITransferWithBeneficiary {
    function transferWithBeneficiary(address token, uint256 amount, address beneficiary, uint64 data)
        external
        returns (bool);
}

interface IERC20Pull {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract UsdtLike {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        name = "Tether USD";
        symbol = "USDT";
        decimals = 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    // USDT transfer returns no bool.
    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    // USDT approve returns no bool.
    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    // USDT transferFrom returns no bool.
    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract ReturningToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        name = "Compliant USD";
        symbol = "USDC";
        decimals = 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function increaseAllowance(address spender, uint256 added) external returns (bool) {
        allowance[msg.sender][spender] += added;
        return true;
    }
}

contract ContractWallet {
    function transferWithBeneficiary(address token, uint256 amount, address beneficiary, uint64)
        external
        returns (bool)
    {
        bool pulled = IERC20Pull(token).transferFrom(msg.sender, beneficiary, amount);
        require(pulled, "pull");
        return true;
    }
}

contract MesonRelease {
    function releaseToContract(address token, address contractAddr, address beneficiary, uint256 amount) external {
        uint256 adjustedAmount = amount;
        // @> VULN: increaseAllowance is not ERC-20. USDT does not implement it and returns no bool, so this reverts and the transfer to the contract never commits.
        IERC20Minimal(token).increaseAllowance(contractAddr, adjustedAmount);
        ITransferWithBeneficiary(contractAddr).transferWithBeneficiary(token, adjustedAmount, beneficiary, 1);
    }
}

contract Exploit {
    uint256 public constant N = 1000e6;
    address public constant BENEFICIARY = 0x2222222222222222222222222222222222222222;

    UsdtLike public usdt;
    ReturningToken public standard;
    ContractWallet public wallet;
    MesonRelease public pool;

    uint256 public parked;
    bool public usdtReleased;
    uint256 public stuck;
    uint256 public usdtPaid;
    uint256 public allowanceLeft;
    uint256 public controlReceived;
    uint256 public standardLeft;

    function run() external {
        usdt = new UsdtLike();
        standard = new ReturningToken();
        wallet = new ContractWallet();
        pool = new MesonRelease();

        usdt.mint(address(pool), N);
        parked = usdt.balanceOf(address(pool));

        bool released = true;
        try pool.releaseToContract(address(usdt), address(wallet), BENEFICIARY, N) {
            released = true;
        } catch {
            released = false;
        }

        usdtReleased = released;
        stuck = usdt.balanceOf(address(pool));
        usdtPaid = usdt.balanceOf(BENEFICIARY);
        allowanceLeft = usdt.allowance(address(pool), address(wallet));

        standard.mint(address(pool), N);
        pool.releaseToContract(address(standard), address(wallet), BENEFICIARY, N);
        controlReceived = standard.balanceOf(BENEFICIARY);
        standardLeft = standard.balanceOf(address(pool));

        require(parked == N, "parked");
        require(usdtReleased == false, "usdt release returned");
        require(stuck == N, "stuck");
        require(usdtPaid == 0, "usdt paid");
        require(allowanceLeft == 0, "allowance committed");
        require(controlReceived == N, "control");
        require(standardLeft == 0, "standard left");
    }
}
