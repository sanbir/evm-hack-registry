// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*
 * Synthetic PoC for AuditVault finding 18536 (Y2K Earthquake / Carousel, Sherlock 2023-03).
 *
 * When a winning depositor enlists a rollover, mintRollovers burns their
 * previous-epoch shares and remints only queue.assets - relayerFee into the
 * next epoch. previewWithdraw would have paid claimTVL/finalTVL (the original
 * deposit PLUS the winnings). Those winnings are not reminted and the old
 * shares are gone, so the depositor cannot withdraw them. They stay in the vault.
 *
 * Reduced from Earthquake/src/v2/Carousel/Carousel.sol mintRollovers
 * (sherlock-audit/2023-03-Y2K). Emission-token bookkeeping is omitted: the
 * audited code does transfer emissions out. The harmed asset is the underlying
 * winning payout, which is not reminted. No cheatcodes.
 *
 * HARM: depositor was entitled to 1_500 ether, receives 999 ether (1_000 deposit
 * minus the 1 ether relayer fee), and 500 ether of previous-epoch winnings
 * remain stuck in the vault.
 */

contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

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

contract Carousel {
    struct QueueItem {
        uint256 assets;
        address receiver;
        uint256 epochId;
    }

    MiniToken public asset;
    uint256 public relayerFee;
    uint256 public zeroPayouts;
    uint256 public lastAssetsToMint;
    uint256 public lastEntitledShares;

    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(uint256 => uint256) public finalTVL;
    mapping(uint256 => uint256) public claimTVL;
    mapping(uint256 => bool) public epochResolved;
    mapping(address => uint256) public ownerToRollOverQueueIndex;
    QueueItem[] public rolloverQueue;

    constructor(address _asset, uint256 _fee) {
        asset = MiniToken(_asset);
        relayerFee = _fee;
    }

    function deposit(uint256 _id, uint256 _assets) external {
        asset.transferFrom(msg.sender, address(this), _assets);
        balanceOf[msg.sender][_id] += _assets;
        finalTVL[_id] += _assets;
    }

    function resolveWin(uint256 _id, uint256 _claimTVL) external {
        uint256 deposited = finalTVL[_id];
        uint256 extra = _claimTVL - deposited;
        if (extra > 0) {
            asset.transferFrom(msg.sender, address(this), extra);
        }
        claimTVL[_id] = _claimTVL;
        epochResolved[_id] = true;
    }

    /// @notice Quoted enlist path: the queued amount is the original deposit.
    function enlistInRollover(uint256 _epochId, uint256 _assets, address _receiver) external {
        require(msg.sender == _receiver, "not receiver");
        require(balanceOf[_receiver][_epochId] >= _assets, "insufficient");
        rolloverQueue.push(QueueItem({assets: 0, receiver: _receiver, epochId: _epochId}));
        uint256 index = rolloverQueue.length - 1;
        rolloverQueue[index].assets = _assets;
        ownerToRollOverQueueIndex[_receiver] = rolloverQueue.length;
    }

    function previewWithdraw(uint256 _id, uint256 _assets) public view returns (uint256 entitledAmount) {
        entitledAmount = _assets * claimTVL[_id] / finalTVL[_id];
    }

    function mintRollovers(uint256 _epochId, uint256 _operations) external {
        uint256 length = rolloverQueue.length;
        uint256 index;
        if (_operations > length) _operations = length;

        QueueItem[] memory queue = rolloverQueue;
        uint256 prevIndex = index;
        uint256 executions;

        while ((index - prevIndex) < _operations) {
            if (epochResolved[queue[index].epochId]) {
                uint256 entitledShares = previewWithdraw(
                    queue[index].epochId,
                    queue[index].assets
                );
                // mint only if user won epoch he is rolling over
                if (entitledShares > queue[index].assets) {
                    // skip the rollover for the user if the assets cannot cover the relayer fee instead of revert.
                    if (queue[index].assets < relayerFee) {
                        index++;
                        continue;
                    }
                    lastEntitledShares = entitledShares;
                    // @note we know shares were locked up to this point
                    _burn(
                        queue[index].receiver,
                        queue[index].epochId,
                        queue[index].assets
                    );
                    // @> VULN: remints the original deposit minus fee, not entitledShares, so previous-epoch winnings are dropped
                    uint256 assetsToMint = queue[index].assets - relayerFee;
                    lastAssetsToMint = assetsToMint;
                    _mintShares(queue[index].receiver, _epochId, assetsToMint);
                    rolloverQueue[index].assets = assetsToMint;
                    rolloverQueue[index].epochId = _epochId;
                    executions++;
                }
            }
            index++;
        }

        if (executions * relayerFee > 0) {
            asset.transfer(msg.sender, executions * relayerFee);
        }
    }

    /// @notice Control path: roll entitledShares (deposit + winnings), minus the relayer fee.
    function mintRolloversFixed(uint256 _epochId, uint256 _operations) external {
        uint256 length = rolloverQueue.length;
        uint256 index;
        if (_operations > length) _operations = length;

        QueueItem[] memory queue = rolloverQueue;
        uint256 prevIndex = index;
        uint256 executions;

        while ((index - prevIndex) < _operations) {
            if (epochResolved[queue[index].epochId]) {
                uint256 entitledShares = previewWithdraw(
                    queue[index].epochId,
                    queue[index].assets
                );
                if (entitledShares > queue[index].assets) {
                    if (queue[index].assets < relayerFee) {
                        index++;
                        continue;
                    }
                    _burn(
                        queue[index].receiver,
                        queue[index].epochId,
                        queue[index].assets
                    );
                    // FIX: remint the entitled payout, so previous-epoch winnings roll forward.
                    uint256 assetsToMint = entitledShares - relayerFee;
                    _mintShares(queue[index].receiver, _epochId, assetsToMint);
                    rolloverQueue[index].assets = assetsToMint;
                    rolloverQueue[index].epochId = _epochId;
                    executions++;
                }
            }
            index++;
        }

        if (executions * relayerFee > 0) {
            asset.transfer(msg.sender, executions * relayerFee);
        }
    }

    function withdraw(uint256 _id) external returns (uint256 paid) {
        uint256 shares = balanceOf[msg.sender][_id];
        if (shares == 0) {
            zeroPayouts += 1;
            return 0;
        }
        _burn(msg.sender, _id, shares);
        uint256 entitledShares = shares;
        if (epochResolved[_id]) {
            entitledShares = previewWithdraw(_id, shares);
        }
        asset.transfer(msg.sender, entitledShares);
        paid = entitledShares;
    }

    function _burn(address owner, uint256 id, uint256 amount) internal {
        balanceOf[owner][id] -= amount;
    }

    function _mintShares(address to, uint256 id, uint256 amount) internal {
        balanceOf[to][id] += amount;
    }
}

contract Depositor {
    function approveAndDeposit(Carousel vault, MiniToken token, uint256 epochId, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.deposit(epochId, amount);
    }

    function enlist(Carousel vault, uint256 epochId, uint256 amount) external {
        vault.enlistInRollover(epochId, amount, address(this));
    }

    function withdraw(Carousel vault, uint256 epochId) external returns (uint256) {
        return vault.withdraw(epochId);
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 1_000 ether;
    uint256 public constant WINNINGS = 500 ether;
    uint256 public constant CLAIM = 1_500 ether;
    uint256 public constant FEE = 1 ether;
    uint256 public constant EPOCH_PREV = 1;
    uint256 public constant EPOCH_NEXT = 2;

    address public assetAddr;
    address public vaultAddr;
    address public userAddr;
    uint256 public entitledBefore;
    uint256 public userReceived;
    uint256 public oldEpochPayout;
    uint256 public lostWinnings;
    uint256 public controlUserReceived;
    uint256 public controlVaultLeft;

    function run() external {
        MiniToken asset = new MiniToken("Earthquake Asset", "EQ");
        Carousel vault = new Carousel(address(asset), FEE);
        Depositor user = new Depositor();
        assetAddr = address(asset);
        vaultAddr = address(vault);
        userAddr = address(user);

        asset.mint(address(user), DEPOSIT);
        asset.mint(address(this), WINNINGS);
        user.approveAndDeposit(vault, asset, EPOCH_PREV, DEPOSIT);
        asset.approve(address(vault), WINNINGS);
        vault.resolveWin(EPOCH_PREV, CLAIM);
        user.enlist(vault, EPOCH_PREV, DEPOSIT);
        entitledBefore = vault.previewWithdraw(EPOCH_PREV, DEPOSIT);
        vault.mintRollovers(EPOCH_NEXT, 1);
        userReceived = user.withdraw(vault, EPOCH_NEXT);
        oldEpochPayout = user.withdraw(vault, EPOCH_PREV);
        lostWinnings = asset.balanceOf(address(vault));

        require(entitledBefore == CLAIM, "entitled");
        require(vault.lastAssetsToMint() == DEPOSIT - FEE, "reminted principal");
        require(vault.lastEntitledShares() == CLAIM, "saw winnings");
        require(userReceived == DEPOSIT - FEE, "principal only");
        require(oldEpochPayout == 0, "old epoch paid");
        require(lostWinnings == WINNINGS, "winnings not lost");
        require(asset.balanceOf(address(user)) == DEPOSIT - FEE, "user missing winnings");
    }

    function control() external {
        MiniToken asset = new MiniToken("Earthquake Asset", "EQ");
        Carousel vault = new Carousel(address(asset), FEE);
        Depositor user = new Depositor();

        asset.mint(address(user), DEPOSIT);
        asset.mint(address(this), WINNINGS);
        user.approveAndDeposit(vault, asset, EPOCH_PREV, DEPOSIT);
        asset.approve(address(vault), WINNINGS);
        vault.resolveWin(EPOCH_PREV, CLAIM);
        user.enlist(vault, EPOCH_PREV, DEPOSIT);
        vault.mintRolloversFixed(EPOCH_NEXT, 1);
        controlUserReceived = user.withdraw(vault, EPOCH_NEXT);
        uint256 oldPayout = user.withdraw(vault, EPOCH_PREV);
        controlVaultLeft = asset.balanceOf(address(vault));

        require(oldPayout == 0, "control old epoch");
        require(controlVaultLeft == 0, "control stuck");
        require(controlUserReceived == CLAIM - FEE, "control short");
        require(controlUserReceived - (DEPOSIT - FEE) == WINNINGS, "winnings not preserved");
    }
}
