// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

// Libraries
import {Fees} from "./libraries/Fees.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {SirStructs} from "./libraries/SirStructs.sol";
import {Clone} from "lib/clones-with-immutable-args/src/Clone.sol";

// Contracts
import {Vault} from "./Vault.sol";

/**
 * @notice Every APE token from every vault is its own ERC-20 token.
 * It is deployed during the initialization of the vault.
 * @dev To minimize gas cost we use the ClonesWithImmutableArgs library to replicate the contract.
 * APE is a mod from Solmate's ERC20.sol
 */
contract APE is Clone {
    error PermitDeadlineExpired();
    error InvalidSigner();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    address public debtToken;
    address public collateralToken;

    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 private immutable INITIAL_CHAIN_ID;

    mapping(address => uint256) public nonces;

    /*///////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    modifier onlyVault() {
        address vault = _getArgAddress(1);
        require(vault == msg.sender);
        _;
    }

    constructor() {
        INITIAL_CHAIN_ID = block.chainid;
    }

    /**
     * @dev Initializes the contract. It is called by the vault.
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address debtToken_,
        address collateralToken_
    ) external onlyVault {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        debtToken = debtToken_;
        collateralToken = collateralToken_;
    }

    /**
     * @notice Returns the current leverage tier.
     */
    function leverageTier() public pure returns (int8) {
        return int8(_getArgUint8(0));
    }

    /*///////////////////////////////////////////////////////////////
                              IERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the allowance of `spender` to `amount`.
     */
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    /**
     * @notice Transfers `amount` tokens to `to`.
     */
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    /**
     * @notice Transfers `amount` tokens from `from` to `to`.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    /*///////////////////////////////////////////////////////////////
                              EIP-2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (deadline < block.timestamp) revert PermitDeadlineExpired();

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            if (recoveredAddress == address(0) || recoveredAddress != owner) revert InvalidSigner();

            allowance[recoveredAddress][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? bytes32(_getArgUint256(21)) : _computeDomainSeparator();
    }

    function _computeDomainSeparator() private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(name)),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    /*///////////////////////////////////////////////////////////////
                       MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The vault contract calls this function to mint APE.
     * It splits the collateral amount between the minter, stakers and POL and updates the total supply and balances.
     */
    function mint(
        address to,
        uint16 baseFee,
        uint8 tax,
        SirStructs.Reserves memory reserves,
        uint144 collateralDeposited
    ) external onlyVault returns (SirStructs.Reserves memory newReserves, SirStructs.Fees memory fees, uint256 amount) {
        // Loads supply of APE
        uint256 supplyAPE = totalSupply;

        // Substract fees
        fees = Fees.feeAPE(collateralDeposited, baseFee, leverageTier(), tax);

        unchecked {
            // Mint APE
            amount = supplyAPE == 0 // By design reserveApes can never be 0 unless it is the first mint ever
                ? fees.collateralInOrWithdrawn + reserves.reserveApes // Any ownless APE reserve is minted by the first ape
                : FullMath.mulDiv(supplyAPE, fees.collateralInOrWithdrawn, reserves.reserveApes);
            balanceOf[to] += amount; // If it OF, so will totalSupply
        }

        reserves.reserveApes += fees.collateralInOrWithdrawn;
        totalSupply = supplyAPE + amount; // Checked math to ensure totalSupply never overflows
        emit Transfer(address(0), to, amount);

        newReserves = reserves; // Important because memory is not persistent across external calls
    }

    /**
     * @dev The vault contract calls this function when a user burns APE.
     * It splits the collateral amount between the minter, stakers and POL and updates the total supply and balances.
     */
    function burn(
        address from,
        uint16 baseFee,
        uint8 tax,
        SirStructs.Reserves memory reserves,
        uint256 amount
    ) external onlyVault returns (SirStructs.Reserves memory newReserves, SirStructs.Fees memory fees) {
        // Loads supply of APE
        uint256 supplyAPE = totalSupply;

        // Burn APE
        uint144 collateralOut = uint144(FullMath.mulDiv(reserves.reserveApes, amount, supplyAPE)); // Compute amount of collateral
        balanceOf[from] -= amount; // Checks for underflow
        unchecked {
            totalSupply = supplyAPE - amount;
            reserves.reserveApes -= collateralOut;

            // Substract fees
            fees = Fees.feeAPE(collateralOut, baseFee, leverageTier(), tax);

            newReserves = reserves; // Important because memory is not persistent across external calls
        }
        emit Transfer(from, address(0), amount);
    }
}
