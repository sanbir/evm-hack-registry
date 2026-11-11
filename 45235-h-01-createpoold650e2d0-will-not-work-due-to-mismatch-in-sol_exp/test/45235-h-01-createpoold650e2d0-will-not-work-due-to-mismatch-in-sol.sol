// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Superposition SeawaterAMM — createPoolD650E2D0 does not match the Stylus
    create_pool entry (Code4rena, ZanyBonzy, H-01, October 2024).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    There is no Stylus VM here. The Rust entry is an external contract.
    Solidity encodes five arguments under createPoolD650E2D0's selector.
    The Stylus entry only accepts create_pool_D650_E2_D0(address,uint256,uint32).
    The five-argument selector hits the fallback and reverts, so the pool is
    never created and a deposit of N cannot land. Production uses directDelegate
    to the stylus executor; this model uses an external call, as a delegate
    into a Stylus program cannot be executed in this environment.
    Vulnerable line preserved below (@> VULN). */

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "token: balance");
        require(allowance[from][msg.sender] >= amt, "token: allowance");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Stand-in for the Stylus program. The matching entry takes three arguments.
contract StylusPool {
    bool public created;
    address public pool;
    uint256 public price;
    uint32 public fee;
    uint256 public liquidity;

    function create_pool_D650_E2_D0(address pool_, uint256 price_, uint32 fee_) external {
        pool = pool_;
        price = price_;
        fee = fee_;
        created = true;
    }

    function addLiquidity(uint256 amount) external {
        require(created, "no pool");
        liquidity += amount;
    }

    fallback() external {
        revert("stylus: wrong selector");
    }
}

contract SeawaterAMM {
    StylusPool public stylus;
    MockToken public token;

    constructor(StylusPool _stylus, MockToken _token) {
        stylus = _stylus;
        token = _token;
    }

    function createPoolD650E2D0(
        address /* token */,
        uint256 /* sqrtPriceX96 */,
        uint32 /* fee */,
        uint8 /* tickSpacing */,
        uint128 /* maxLiquidityPerTick */
    ) external {
        // @> VULN: five-argument selector; Stylus create_pool_D650_E2_D0 takes pool, price, fee
        (bool ok, bytes memory ret) = address(stylus).call(msg.data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function deposit(uint256 amount) external {
        require(stylus.created(), "no pool");
        token.transferFrom(msg.sender, address(this), amount);
        stylus.addLiquidity(amount);
    }
}

contract SeawaterAMMFixed {
    StylusPool public stylus;
    MockToken public token;

    constructor(StylusPool _stylus, MockToken _token) {
        stylus = _stylus;
        token = _token;
    }

    function createPoolMatching(address pool, uint256 sqrtPriceX96, uint32 fee) external {
        (bool ok, bytes memory ret) = address(stylus).call(
            abi.encodeWithSelector(StylusPool.create_pool_D650_E2_D0.selector, pool, sqrtPriceX96, fee)
        );
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function deposit(uint256 amount) external {
        require(stylus.created(), "no pool");
        token.transferFrom(msg.sender, address(this), amount);
        stylus.addLiquidity(amount);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    MockToken public token;
    StylusPool public stylus;
    SeawaterAMM public amm;
    bool public createReverted;
    bool public depositReverted;

    constructor() {
        token = new MockToken();
        stylus = new StylusPool();
        amm = new SeawaterAMM(stylus, token);
    }

    function run() external {
        token.mint(address(this), N);
        token.approve(address(amm), N);

        (bool created,) = address(amm).call(
            abi.encodeWithSelector(
                amm.createPoolD650E2D0.selector,
                address(token),
                uint256(1 << 96),
                uint32(3000),
                uint8(60),
                uint128(N)
            )
        );
        require(!created, "createPool did not revert");
        createReverted = true;
        require(!stylus.created(), "pool was created");

        (bool deposited,) = address(amm).call(abi.encodeWithSelector(amm.deposit.selector, N));
        require(!deposited, "deposit did not revert");
        depositReverted = true;
        require(token.balanceOf(address(this)) == N, "liquidity left the caller");
        require(stylus.liquidity() == 0, "liquidity was recorded");
    }
}
