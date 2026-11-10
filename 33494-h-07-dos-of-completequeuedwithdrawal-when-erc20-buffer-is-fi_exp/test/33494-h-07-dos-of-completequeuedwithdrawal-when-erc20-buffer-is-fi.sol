// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Renzo OperatorDelegator.completeQueuedWithdrawal — filling the ERC20
    withdrawal buffer calls DepositQueue.fillERC20withdrawBuffer, which
    only the RestakeManager may call (Code4rena H-07, finding 33494).
    SYNTHETIC, cheatcode-free.
    Root cause: a deficit makes completion approve the deposit queue and
    call fillERC20withdrawBuffer. OperatorDelegator is not the
    RestakeManager, so the call reverts and the whole completion reverts.
    The withdrawn tokens never leave EigenLayer. The buffer target is the
    small withdrawal size N, so the entire amount is what the fill owes. */

error NotRestakeManager();
error MismatchedArrayLengths();
error InvalidZeroInput();

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function safeApprove(address spender, uint256 amount) external;
}

struct Withdrawal {
    address[] strategies;
    uint256[] shares;
}

contract EzETH is IERC20 {
    string public name = "Renzo Restaked ETH";
    string public symbol = "ezETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function safeApprove(address spender, uint256 amount) external override {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract WithdrawQueue {
    EzETH public token;
    uint256 public bufferTarget;
    uint256 public bufferFilled;

    constructor(address _token, uint256 _target) {
        token = EzETH(_token);
        bufferTarget = _target;
    }

    function getBufferDeficit(address) external view returns (uint256) {
        if (bufferFilled >= bufferTarget) return 0;
        return bufferTarget - bufferFilled;
    }

    function creditBuffer(uint256 amount) external {
        bufferFilled += amount;
    }
}

contract RestakeManager {
    DepositQueue public depositQueue;

    function setDepositQueue(address queue) external {
        depositQueue = DepositQueue(queue);
    }
}

contract DelegationManager {
    EzETH public token;

    constructor(address _token) {
        token = EzETH(_token);
    }

    function completeQueuedWithdrawal(Withdrawal calldata withdrawal, IERC20[] calldata, uint256, bool) external {
        token.transfer(msg.sender, withdrawal.shares[0]);
    }

    function deposit(address, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }
}

contract DepositQueue {
    address public restakeManager;
    WithdrawQueue public withdrawQueue;
    EzETH public token;

    constructor(address _restakeManager, address _withdrawQueue, address _token) {
        restakeManager = _restakeManager;
        withdrawQueue = WithdrawQueue(_withdrawQueue);
        token = EzETH(_token);
    }

    /// @dev Allows only the RestakeManager address to call functions
    modifier onlyRestakeManager() {
        // @> VULN: OperatorDelegator is not the RestakeManager, so filling the buffer reverts the whole completion
        if (msg.sender != address(restakeManager)) revert NotRestakeManager();
        // FIX: drop onlyRestakeManager. A caller only donates ERC20 into the withdraw queue.
        _;
    }

    function fillERC20withdrawBuffer(address _asset, uint256 _amount) external virtual onlyRestakeManager {
        require(_asset == address(token), "asset");
        token.transferFrom(msg.sender, address(withdrawQueue), _amount);
        withdrawQueue.creditBuffer(_amount);
    }
}

contract OperatorDelegator {
    address public constant IS_NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public nativeEthRestakeAdmin;
    RestakeManager public restakeManager;
    DelegationManager public delegationManager;
    mapping(address => uint256) public queuedShares;
    uint256 private _status = 1;

    constructor(address _admin, address _restakeManager, address _delegationManager) {
        nativeEthRestakeAdmin = _admin;
        restakeManager = RestakeManager(_restakeManager);
        delegationManager = DelegationManager(_delegationManager);
    }

    modifier nonReentrant() {
        require(_status == 1, "reentrant");
        _status = 2;
        _;
        _status = 1;
    }

    modifier onlyNativeEthRestakeAdmin() {
        require(msg.sender == nativeEthRestakeAdmin, "admin");
        _;
    }

    function noteQueuedShares(address token, uint256 shares) external {
        queuedShares[token] = shares;
    }

    function completeQueuedWithdrawal(
        Withdrawal calldata withdrawal,
        IERC20[] calldata tokens,
        uint256 middlewareTimesIndex
    ) external nonReentrant onlyNativeEthRestakeAdmin {
        if (tokens.length != withdrawal.strategies.length) revert MismatchedArrayLengths();

        delegationManager.completeQueuedWithdrawal(withdrawal, tokens, middlewareTimesIndex, true);

        for (uint256 i; i < tokens.length;) {
            if (address(tokens[i]) == address(0)) revert InvalidZeroInput();

            queuedShares[address(tokens[i])] -= withdrawal.shares[i];

            if (address(tokens[i]) != IS_NATIVE) {
                uint256 bufferToFill =
                    restakeManager.depositQueue().withdrawQueue().getBufferDeficit(address(tokens[i]));

                uint256 balanceOfToken = tokens[i].balanceOf(address(this));
                if (bufferToFill > 0) {
                    bufferToFill = (balanceOfToken <= bufferToFill) ? balanceOfToken : bufferToFill;

                    balanceOfToken -= bufferToFill;

                    tokens[i].safeApprove(address(restakeManager.depositQueue()), bufferToFill);

                    restakeManager.depositQueue().fillERC20withdrawBuffer(address(tokens[i]), bufferToFill);
                }

                if (balanceOfToken > 0) {
                    _deposit(tokens[i], balanceOfToken);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _deposit(IERC20 token, uint256 amount) internal {
        token.safeApprove(address(delegationManager), amount);
        delegationManager.deposit(address(token), amount);
    }
}

contract Exploit {
    uint256 public constant N = 100e18;

    EzETH public token; // nonce 1
    WithdrawQueue public withdrawQueue; // nonce 2
    RestakeManager public restakeManager; // nonce 3
    DepositQueue public depositQueue; // nonce 4
    DelegationManager public delegationManager; // nonce 5
    OperatorDelegator public delegator; // nonce 6

    uint256 public funded;
    uint256 public deficit;
    bool public completionReverted;
    uint256 public stuckAmount;
    uint256 public queuePaid;

    constructor() {
        token = new EzETH();
        withdrawQueue = new WithdrawQueue(address(token), N);
        restakeManager = new RestakeManager();
        depositQueue = new DepositQueue(address(restakeManager), address(withdrawQueue), address(token));
        restakeManager.setDepositQueue(address(depositQueue));
        delegationManager = new DelegationManager(address(token));
        delegator = new OperatorDelegator(address(this), address(restakeManager), address(delegationManager));
    }

    function run() external {
        token.mint(address(delegationManager), N);
        funded = token.balanceOf(address(delegationManager));
        deficit = withdrawQueue.getBufferDeficit(address(token));
        require(funded == N, "funded");
        require(deficit == N, "buffer");

        delegator.noteQueuedShares(address(token), N);

        Withdrawal memory withdrawal;
        withdrawal.strategies = new address[](1);
        withdrawal.shares = new uint256[](1);
        withdrawal.strategies[0] = address(token);
        withdrawal.shares[0] = N;

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = token;

        (bool ok,) = address(delegator).call(
            abi.encodeCall(OperatorDelegator.completeQueuedWithdrawal, (withdrawal, tokens, 0))
        );

        completionReverted = !ok;
        stuckAmount = token.balanceOf(address(delegationManager));
        queuePaid = token.balanceOf(address(withdrawQueue));
        require(completionReverted, "completion did not revert");
        require(stuckAmount == N, "N tokens were not stuck");
        require(queuePaid == 0, "queue was paid");
    }
}
