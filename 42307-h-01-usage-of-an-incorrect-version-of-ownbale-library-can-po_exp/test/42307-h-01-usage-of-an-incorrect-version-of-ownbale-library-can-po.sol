// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Covalent DelegatedStaking — non-upgradeable Ownable behind a proxy
    (Code4rena H-01, AuditVault 42307). SYNTHETIC, cheatcode-free.

    The audited contract imports Ownable.sol, not OwnableUpgradeable, and
    initialize does not call __Ownable_init. The Ownable constructor writes
    the owner on the implementation. The proxy's owner slot stays address(0).
    takeOutRewardTokens reverts for the deployer. 1000 CQT sitting on the
    proxy cannot be withdrawn.

    Verbatim initialize from DelegatedStaking.sol at
    code-423n4/2021-10-covalent@ded3aeb2476da553e8bb1fe43358b73334434737:

        function initialize(uint128 minStakedRequired) public initializer {
            validatorMinStakedRequired = minStakedRequired;
            // no __Ownable_init
        }

    The control calls __Ownable_init inside initialize. The same takeOut
    then sends the 1000 CQT to the owner. */

contract Cqt {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Ownable {
    address private _owner;

    constructor() {
        _owner = msg.sender;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        // @> VULN: proxy storage never received the constructor write, so _owner is address(0) and the real owner is rejected
        require(msg.sender == _owner, "Ownable: caller is not the owner");
        _;
    }
}

contract Initializable {
    uint8 private _initialized;

    modifier initializer() {
        require(_initialized == 0, "init");
        _initialized = 1;
        _;
    }
}

contract DelegatedStaking is Ownable, Initializable {
    Cqt public immutable cqt;
    uint128 public validatorMinStakedRequired;
    uint128 public rewardsLocked;

    constructor(Cqt _cqt) {
        cqt = _cqt;
    }

    function initialize(uint128 minStakedRequired) public initializer {
        validatorMinStakedRequired = minStakedRequired;
        rewardsLocked = minStakedRequired;
    }

    function takeOutRewardTokens(uint128 amount) public onlyOwner {
        require(amount > 0, "Amount is 0");
        require(rewardsLocked >= amount, "Amount is greater than available");
        rewardsLocked -= amount;
        cqt.transfer(owner(), uint256(amount));
    }
}

contract Proxy {
    bytes32 internal constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address impl) {
        assembly {
            sstore(SLOT, impl)
        }
    }

    fallback() external payable {
        assembly {
            let impl := sload(SLOT)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

interface IStaking {
    function initialize(uint128 minStakedRequired) external;
    function takeOutRewardTokens(uint128 amount) external;
    function owner() external view returns (address);
    function rewardsLocked() external view returns (uint128);
}

contract Exploit {
    Cqt public cqt; // nonce 1
    DelegatedStaking public impl; // nonce 2
    Proxy public proxy; // nonce 3

    constructor() {
        cqt = new Cqt();
        impl = new DelegatedStaking(cqt);
        proxy = new Proxy(address(impl));
    }

    function run() external {
        cqt.mint(address(proxy), 1000 ether);
        IStaking staking = IStaking(address(proxy));
        staking.initialize(uint128(1000 ether));
        address proxyOwner = staking.owner();
        address implOwner = impl.owner();
        uint128 locked = staking.rewardsLocked();
        (bool ok,) = address(proxy).call(
            abi.encodeWithSelector(staking.takeOutRewardTokens.selector, uint128(1000 ether))
        );
        uint256 stuck = cqt.balanceOf(address(proxy));
        require(implOwner == address(this), "impl owner is deployer");
        require(proxyOwner == address(0), "proxy owner is zero");
        require(locked == uint128(1000 ether), "rewards recorded");
        require(!ok, "takeOut reverted");
        require(stuck == 1000 ether, "1000 CQT stuck");
    }
}
