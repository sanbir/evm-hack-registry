// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bando — beneficiaries cannot withdraw a fulfilled balance
    (Zokyo, finding #45848, report 2024-11-25)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: BandoERC20FulfillableV1.beneficiaryWithdraw (and the native
    twin) revert unless msg.sender is the manager, but the audited
    BandoFulfillmentManagerV1 has no function that calls it. Fulfilled
    tokens sit in the escrow forever.

    The gate below is the line the report quotes, copied verbatim.
    The payout that follows snapshots the pool first, matching
    BandoFulfillableV1.beneficiaryWithdraw at the same commit, so the
    ONLY missing piece is the manager withdraw. A later zero-after-clear
    in the ERC20 sibling is a different bug and is not reproduced here.

    Source: bandohq/evm-fulfillment-protocol@b901030
    contracts/BandoERC20FulfillableV1.sol beneficiaryWithdraw
    contracts/BandoFulfillmentManagerV1.sol (no beneficiaryWithdraw)
*/

contract MockToken {
    string public constant name = "Bando";
    string public constant symbol = "BAND";
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract FulfillableRegistry {
    struct Service {
        uint256 serviceId;
        address fulfiller;
        address payable beneficiary;
        uint256 feeAmount;
    }

    mapping(uint256 => Service) internal _services;

    function setService(uint256 serviceID, address payable beneficiary) external {
        _services[serviceID] = Service({
            serviceId: serviceID,
            fulfiller: msg.sender,
            beneficiary: beneficiary,
            feeAmount: 0
        });
    }

    function getService(uint256 serviceID) external view returns (Service memory) {
        return _services[serviceID];
    }

    function beneficiaryOf(uint256 serviceID) external view returns (address payable) {
        return _services[serviceID].beneficiary;
    }
}

/// @title BandoERC20FulfillableV1 (reduced)
/// @notice Escrow that holds a beneficiary's fulfilled balance.
contract BandoERC20FulfillableV1 {
    struct Service {
        uint256 serviceId;
        address fulfiller;
        address payable beneficiary;
        uint256 feeAmount;
    }

    address public _manager;
    FulfillableRegistry private _registryContract;
    mapping(address => uint256) public _releaseablePools;
    uint256 private _locked;

    modifier nonReentrant() {
        require(_locked == 0, "reentrant");
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor(address registry_) {
        _registryContract = FulfillableRegistry(registry_);
    }

    function setManager(address manager_) external {
        require(_manager == address(0), "manager already set");
        require(manager_ != address(0), "Manager cannot be the zero address");
        _manager = manager_;
    }

    /// Success branch of registerFulfillment: the manager credits the pool
    /// after the tokens have already been pulled into this contract.
    function registerFulfillment(uint256 serviceID, address token, uint256 amount) external {
        require(_manager == msg.sender, "Caller is not the manager");
        require(serviceID != 0, "Service ID is invalid");
        require(amount > 0, "There is no balance to release.");
        _releaseablePools[token] += amount;
    }

    /// @dev Withdraws the beneficiary's available balance to release (fulfilled with success).
    ///      Report quote: only the manager may call this.
    function beneficiaryWithdraw(uint256 serviceID, address token) public virtual nonReentrant {
        // @> VULN: only the manager may withdraw, and BandoFulfillmentManagerV1 never calls this
        require(_manager == msg.sender, "Caller is not the manager");
        // FIX: add manager.beneficiaryWithdraw that the beneficiary can call, which calls this
        address payable beneficiary = _registryContract.beneficiaryOf(serviceID);
        require(_releaseablePools[token] > 0, "There is no balance to release.");
        uint256 amount = _releaseablePools[token];
        _releaseablePools[token] = 0;
        MockToken(token).transfer(beneficiary, amount);
    }
}

/// @title Audited manager — registerFulfillment exists, beneficiaryWithdraw does not.
contract BandoFulfillmentManagerV1 {
    address public _escrow;

    constructor(address escrow_) {
        _escrow = escrow_;
    }

    function registerFulfillment(uint256 serviceID, address token, uint256 amount) external {
        MockToken(token).transferFrom(msg.sender, _escrow, amount);
        BandoERC20FulfillableV1(_escrow).registerFulfillment(serviceID, token, amount);
    }
}

/// @title Control: the same manager plus the missing withdraw. Pays the beneficiary N.
contract BandoFulfillmentManagerFixed {
    address public _escrow;
    FulfillableRegistry public registry;

    constructor(address escrow_, address registry_) {
        _escrow = escrow_;
        registry = FulfillableRegistry(registry_);
    }

    function registerFulfillment(uint256 serviceID, address token, uint256 amount) external {
        MockToken(token).transferFrom(msg.sender, _escrow, amount);
        BandoERC20FulfillableV1(_escrow).registerFulfillment(serviceID, token, amount);
    }

    function beneficiaryWithdraw(uint256 serviceID, address token) external {
        require(registry.beneficiaryOf(serviceID) == msg.sender, "Only the beneficiary can withdraw");
        BandoERC20FulfillableV1(_escrow).beneficiaryWithdraw(serviceID, token);
    }
}

contract Exploit {
    uint256 public constant LOCKED = 1000 ether;
    uint256 public constant SERVICE_ID = 1;
    address public constant BENEFICIARY = 0x2222222222222222222222222222222222222222;

    MockToken public token;
    FulfillableRegistry public registry;
    BandoERC20FulfillableV1 public escrow;
    BandoFulfillmentManagerV1 public manager;

    uint256 public stuck;
    bool public directWithdrawSucceeded;
    bool public managerWithdrawSucceeded;

    function run() external {
        token = new MockToken();
        registry = new FulfillableRegistry();
        escrow = new BandoERC20FulfillableV1(address(registry));
        manager = new BandoFulfillmentManagerV1(address(escrow));
        escrow.setManager(address(manager));
        registry.setService(SERVICE_ID, payable(BENEFICIARY));

        token.mint(address(this), LOCKED);
        token.approve(address(manager), LOCKED);
        manager.registerFulfillment(SERVICE_ID, address(token), LOCKED);

        uint256 sitting = token.balanceOf(address(escrow));
        require(sitting == LOCKED, "pool not funded");

        (bool directOk,) = address(escrow).call(
            abi.encodeWithSignature("beneficiaryWithdraw(uint256,address)", SERVICE_ID, address(token))
        );
        directWithdrawSucceeded = directOk;
        require(!directOk, "direct withdraw should revert");

        (bool mgrOk,) = address(manager).call(
            abi.encodeWithSignature("beneficiaryWithdraw(uint256,address)", SERVICE_ID, address(token))
        );
        managerWithdrawSucceeded = mgrOk;
        require(!mgrOk, "manager withdraw should not exist");

        stuck = token.balanceOf(address(escrow));
        require(stuck == LOCKED, "funds not stuck");
        require(token.balanceOf(BENEFICIARY) == 0, "beneficiary was paid");
    }
}
