// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std-1.9.4/Test.sol";
import {Game, OwnableUpgradeable, PausableUpgradeable} from "../src/Game.sol";
import {Artcade, TLUniversalDeployer} from "../src/Artcade.sol";
import {ERC721TL} from "tl-creator-contracts-3.3.1/erc-721/ERC721TL.sol";
import {WETH9} from "tl-sol-tools-3.1.4/../test/utils/WETH9.sol";
import {GameEIP712} from "./utils/GameEIP712.sol";

contract GameTest is Test {
    ERC721TL public nft;
    GameEIP712 public signerContract;
    Game public game;

    address weth;

    address artcade = makeAddr("artcade");
    address feeRecipient = makeAddr("feeRecipient");
    address signer;
    uint256 privateKey;

    uint256 maxScore = 10_000;

    function setUp() public {
        // deploy weth
        weth = address(new WETH9());

        // setup signer
        (signer, privateKey) = makeAddrAndKey("signer");

        // deploy game contract
        game = new Game(false);

        // deploy nft contract
        address[] memory admins = new address[](1);
        admins[0] = address(game);
        nft = new ERC721TL(false);
        nft.initialize("TEST", "TEST", "", address(this), 1000, address(this), admins, true, address(0), address(0));

        // deploy signer contract
        signerContract = new GameEIP712("Test Game", address(game));

        // initialize game
        vm.prank(artcade);
        game.initialize(
            address(this), "Test Game", "https://test.com/metadata", address(nft), signer, maxScore, feeRecipient
        );
    }

    function test_constructor() public {
        Game g = new Game(true);

        vm.expectRevert();
        g.initialize(
            address(this), "Test Game", "https://test.com/metadata", address(nft), signer, maxScore, feeRecipient
        );
    }

    function test_registerPlayer(address player, address player2) public {
        vm.assume(player != address(0));
        vm.assume(player2 != address(0));
        vm.assume(player != player2);

        // register player
        vm.prank(player);
        vm.expectEmit(true, true, true, true);
        emit Game.PlayerRegistered(player, 1);
        game.registerPlayer(player);

        // ensure player is registered and owns NFT
        assertEq(game.getPlayerNft(player), 1);
        assertEq(nft.ownerOf(1), player);
        assertEq(nft.tokenURI(1), "https://test.com/metadata/1");

        // try registering again and verify revert
        vm.prank(player);
        vm.expectRevert(Game.PlayerAlreadyRegistered.selector);
        game.registerPlayer(player);

        // try registering player2 using player and verify success
        vm.prank(player);
        vm.expectEmit(true, true, true, true);
        emit Game.PlayerRegistered(player2, 2);
        game.registerPlayer(player2);
        assertEq(game.getPlayerNft(player2), 2);
        assertEq(nft.ownerOf(2), player2);
        assertEq(nft.tokenURI(2), "https://test.com/metadata/2");
    }

    function test_submitScore(
        address player,
        address player2,
        uint256 score,
        uint256 pricePerGame,
        uint16 protocolFeeBps,
        uint64 maxTicketPerGame
    ) public {
        vm.assume(player != address(0) && player != feeRecipient && player != artcade);
        vm.assume(player2 != address(0));
        vm.assume(player != player2);
        vm.assume(pricePerGame > 0);

        // limit pricePerGame from 1 wei to 100 ether
        if (pricePerGame > 100 ether) {
            pricePerGame %= 100 ether + 1;
        }

        // limit protocolFeeBps to 9000
        if (protocolFeeBps > 9000) {
            protocolFeeBps %= 9000;
        }

        // limit score to maxScore
        if (score > maxScore) {
            score %= maxScore;
        }

        // deal eth to player
        vm.deal(player, 300 ether);

        // mock calls for artcade so `artcade.dispenseTickets()` and `artcade.settings()` works
        vm.mockCall(
            artcade,
            abi.encodeWithSelector(Artcade.getSettings.selector),
            abi.encode(
                Artcade.Settings({
                    pricePerGame: uint256(pricePerGame),
                    maxTicketPerGame: uint256(maxTicketPerGame),
                    ticketAddress: address(1),
                    ticketTokenId: 1,
                    protocolFeeRecipient: artcade,
                    protocolFeeBps: uint256(protocolFeeBps),
                    weth: weth,
                    gameImplementationAddress: address(game),
                    universalDeployer: TLUniversalDeployer(address(2)),
                    contractType: "ERC721TL",
                    versionIndex: 0
                })
            )
        );

        vm.mockCall(artcade, abi.encodeWithSelector(Artcade.dispenseTickets.selector), hex"");

        // try submitting score before player is registered
        vm.prank(player);
        vm.expectRevert(Game.PlayerNotRegistered.selector);
        game.submitScore(player, 0, bytes32(0), hex"");

        // try submitting score larger than maxScore
        vm.prank(player);
        vm.expectRevert(Game.InvalidScore.selector);
        game.submitScore(player, maxScore + 1, bytes32(0), hex"");

        // build score and sign it with the `SignerContract` and `privateKey`
        bytes memory signature = signerContract.signScore(privateKey, player, score, bytes32(0));

        // register players
        vm.prank(player);
        game.registerPlayer(player);
        game.registerPlayer(player2);

        // transfer nft to this address and check that submiting score fails
        vm.prank(player);
        nft.transferFrom(player, address(this), 1);
        vm.expectRevert(Game.PlayerDoesNotOwnPlayerNft.selector);
        game.submitScore(player, score, bytes32(0), signature);

        // transfer nft back to player
        nft.transferFrom(address(this), player, 1);

        // submit score with invalid signature params
        // - score doesn't match
        vm.prank(player);
        vm.expectRevert(Game.InvalidSignature.selector);
        game.submitScore(player, score == maxScore ? score - 1 : score + 1, bytes32(0), signature);
        // - score doesn't match nonce
        vm.prank(player);
        vm.expectRevert(Game.InvalidSignature.selector);
        game.submitScore(player, score, bytes32(uint256(1)), signature);
        // - player doesn't match
        vm.prank(player);
        vm.expectRevert(Game.InvalidSignature.selector);
        game.submitScore(player2, score, bytes32(0), signature);

        // submit score from different signer
        signature = signerContract.signScore(uint256(420), player, score, bytes32(0));
        vm.prank(player);
        vm.expectRevert(Game.InvalidSignature.selector);
        game.submitScore(player, score, bytes32(0), signature);

        // generate proper sig
        signature = signerContract.signScore(privateKey, player, score, bytes32(0));

        // submit score without payment
        console.log("hi");
        vm.prank(player);
        vm.expectRevert(Game.InvalidPayment.selector);
        game.submitScore(player, score, bytes32(0), signature);

        // submit score with too much payment
        console.log("bye");
        vm.prank(player);
        vm.expectRevert(Game.InvalidPayment.selector);
        game.submitScore{value: pricePerGame + 1}(player, score, bytes32(0), signature);

        // submit score successfully
        uint256 prevPlayerBalance = player.balance;
        uint256 prevFeeRecipientBalance = feeRecipient.balance;
        uint256 prevArtcadeBalance = artcade.balance;
        vm.prank(player);
        if (score > 0) {
            vm.expectEmit(true, true, true, true);
            emit Game.NewHighScore(player, 1, score);
        }
        game.submitScore{value: pricePerGame}(player, score, bytes32(0), signature);

        // verify score
        uint256 highScore = game.getPlayerHighScore(player);
        assertEq(highScore, score);

        // verify payments transferred successfully
        uint256 protocolFee = pricePerGame * protocolFeeBps / 10_000;
        assertEq(artcade.balance - prevArtcadeBalance, protocolFee);
        assertEq(feeRecipient.balance - prevFeeRecipientBalance, pricePerGame - protocolFee);
        assertEq(prevPlayerBalance - player.balance, pricePerGame);

        // try submitting score again (nonce check fails)
        vm.prank(player);
        vm.expectRevert(Game.NonceUsed.selector);
        game.submitScore{value: pricePerGame}(player, score, bytes32(0), signature);

        // submit new score for player
        signature = signerContract.signScore(privateKey, player, score / 2, bytes32(uint256(1)));
        vm.prank(player);
        game.submitScore{value: pricePerGame}(player, score / 2, bytes32(uint256(1)), signature);

        // submit score for player2 from player address
        signature = signerContract.signScore(privateKey, player2, score, bytes32(uint256(2)));
        vm.prank(player);
        if (score > 0) {
            vm.expectEmit(true, true, true, true);
            emit Game.NewHighScore(player2, 2, score);
        }
        game.submitScore{value: pricePerGame}(player2, score, bytes32(uint256(2)), signature);

        // clear mocked calls
        vm.clearMockedCalls();
    }

    function test_updateSettings(address hacker) public {
        vm.assume(hacker != address(this));

        // make sure hacker can't access and it reverts with proper error
        vm.prank(hacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, hacker));
        game.updateSettings(
            Game.Settings({name: "test", baseUri: "test", signer: hacker, maxScore: 1000, feeRecipient: hacker})
        );

        // make sure owner can access and it succeeds
        vm.prank(address(this));
        game.updateSettings(
            Game.Settings({name: "test", baseUri: "test", signer: hacker, maxScore: 1000, feeRecipient: hacker})
        );

        (string memory name, string memory baseUri, address signer_, uint256 maxScore_, address feeRecipient_) =
            game.settings();

        assertEq(keccak256(bytes(name)), keccak256(bytes("test")));
        assertEq(keccak256(bytes(baseUri)), keccak256(bytes("test")));
        assertEq(signer_, hacker);
        assertEq(maxScore_, 1000);
        assertEq(feeRecipient_, hacker);
    }

    function test_setPaused(address hacker) public {
        vm.assume(hacker != address(this));

        // make sure hacker can't access and it reverts with proper error
        vm.prank(hacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, hacker));
        game.setPaused(true);

        // make sure owner can access and it succeeds
        vm.prank(address(this));
        game.setPaused(true);

        assertEq(game.paused(), true);

        // make sure registering players and submitting scores reverts when paused
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        game.registerPlayer(address(this));

        bytes memory sig = hex"";
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        game.submitScore(address(this), 0, bytes32(0), sig);

        // unpause
        game.setPaused(false);
        assertEq(game.paused(), false);
    }
}
