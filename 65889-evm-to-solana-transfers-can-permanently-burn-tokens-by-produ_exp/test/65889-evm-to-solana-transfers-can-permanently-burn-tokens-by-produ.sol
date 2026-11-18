// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Securitize Solana bridge — EVM burns a value Solana cannot decode (Cyfrin, finding 65889)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _bridgeDSTokensInternal abi-encodes _value as a uint256 and burns it before
    the destination proves it can decode the payload. Solana's u64::try_from rejects
    type(uint64).max + 1, so the burn is final and nothing is minted. The burn is the
    blamed line (@> VULN). */

contract DSToken {
    mapping(address => uint256) public balanceOf;
    uint256 public burned;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount, string memory) external {
        balanceOf[from] -= amount;
        burned += amount;
        balanceOf[address(0x000000000000000000000000000000000000dEaD)] += amount;
    }
}

contract WormholeCore {
    bytes public lastPayload;
    uint64 public sequence;

    function publishMessage(uint32, bytes calldata payload, uint8) external payable returns (uint64) {
        lastPayload = payload;
        sequence += 1;
        return sequence;
    }
}

struct InvestorDetail {
    string investorId;
    string country;
    uint256[] attributeValues;
    int256[] attributeExpirations;
}

contract SolanaBridge {
    uint256 public minted;

    function executeVaa(bytes calldata payload) external returns (bool accepted) {
        (
            uint16 targetChain,
            string memory investorId,
            uint256 value,
            bytes32 sourceWallet,
            bytes32 destination,
            string memory country,
            uint256[] memory attributeValues,
            int256[] memory attributeExpirations
        ) = abi.decode(payload, (uint16, string, uint256, bytes32, bytes32, string, uint256[], int256[]));
        if (value > type(uint64).max) return false;
        if (payload.length > 1024) return false;
        if (attributeValues.length > 8 || attributeExpirations.length > 8) return false;
        if (targetChain == 0 && sourceWallet == destination && bytes(investorId).length == 0 && bytes(country).length == 0) {
            return false;
        }
        minted += value;
        accepted = true;
    }
}

contract SecuritizeBridge {
    DSToken public dsToken;
    WormholeCore public wormholeCore;
    string public constant BRIDGE_REASON = "BRIDGE";

    constructor(DSToken _ds, WormholeCore _core) {
        dsToken = _ds;
        wormholeCore = _core;
    }

    function bridgeDSTokensToAddress(uint16 _targetChain, uint256 _value, bytes32 _destinationAddress) external {
        _bridgeDSTokensInternal(_targetChain, _value, _destinationAddress);
    }

    function _bridgeDSTokensInternal(uint16 _targetChain, uint256 _value, bytes32 _destinationAddress)
        private
        returns (string memory investorId)
    {
        InvestorDetail memory detail;
        detail.investorId = "investor-1";
        detail.country = "US";
        detail.attributeValues = new uint256[](0);
        detail.attributeExpirations = new int256[](0);
        investorId = detail.investorId;
        bytes memory encoded = _encodePayload(
            _targetChain, _value, bytes32(uint256(uint160(msg.sender))), _destinationAddress, detail
        );
        uint64 sequence = wormholeCore.publishMessage(0, encoded, 1);
        require(sequence == 1, "published");
        dsToken.burn(msg.sender, _value, BRIDGE_REASON); // @> VULN: burn runs even when Solana cannot decode _value
        // FIX: if (_targetChain == SOLANA && _value > type(uint64).max) revert();
    }

    function _encodePayload(
        uint16 _targetChain,
        uint256 _value,
        bytes32 _sourceWallet,
        bytes32 _destinationAddress,
        InvestorDetail memory _investorDetail
    ) internal pure returns (bytes memory) {
        return abi.encode(
            _targetChain,
            _investorDetail.investorId,
            _value,
            _sourceWallet,
            _destinationAddress,
            _investorDetail.country,
            _investorDetail.attributeValues,
            _investorDetail.attributeExpirations
        );
    }

    function payload() external view returns (bytes memory) {
        return wormholeCore.lastPayload();
    }
}

contract Exploit {
    uint256 public constant AMOUNT = uint256(type(uint64).max) + 1;
    DSToken public ds; // CREATE nonce 1
    WormholeCore public wormhole; // CREATE nonce 2
    SecuritizeBridge public bridge; // CREATE nonce 3
    SolanaBridge public solana; // CREATE nonce 4
    bool public accepted;

    constructor() {
        ds = new DSToken();
        wormhole = new WormholeCore();
        bridge = new SecuritizeBridge(ds, wormhole);
        solana = new SolanaBridge();
        ds.mint(address(this), AMOUNT);
    }

    function run() external {
        bridge.bridgeDSTokensToAddress(1, AMOUNT, bytes32(uint256(uint160(address(this)))));
        accepted = solana.executeVaa(bridge.payload());
        require(!accepted, "solana rejected");
        require(solana.minted() == 0, "nothing minted");
        require(ds.balanceOf(address(this)) == 0, "user balance burned");
        require(ds.burned() == AMOUNT, "burn recorded");
        require(ds.balanceOf(address(0x000000000000000000000000000000000000dEaD)) == AMOUNT, "sink");
    }

    /// @dev Control entry. Not called from run().
    function bridgeSmall(uint256 amount) external returns (bool) {
        bridge.bridgeDSTokensToAddress(1, amount, bytes32(uint256(uint160(address(this)))));
        return solana.executeVaa(bridge.payload());
    }
}
