// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std-1.9.4/Test.sol";
import {Artcade, TLUniversalDeployer, Ownable} from "../src/Artcade.sol";
import {Game} from "../src/Game.sol";
import {ERC1155TL} from "tl-creator-contracts-3.3.1/erc-1155/ERC1155TL.sol";
import {ERC721TL} from "tl-creator-contracts-3.3.1/erc-721/ERC721TL.sol";
import {WETH9} from "tl-sol-tools-3.1.4/../test/utils/WETH9.sol";
import {GameEIP712} from "./utils/GameEIP712.sol";

contract ArtcadeTest is Test {
    ERC1155TL public ticketContract;
    ERC721TL public nftContract;
    TLUniversalDeployer public deployer;
    address public gameImplementation;
    Artcade public artcade;
    address public weth;
    uint256 public maxTickets = 10_000;
    address signer;
    uint256 privateKey;

    function setUp() public {
        // deploy weth
        weth = address(new WETH9());

        // setup signer
        (signer, privateKey) = makeAddrAndKey("signer");

        // deploy universal deployer
        deployer = new TLUniversalDeployer(address(this));

        // deploy ticket contract
        ticketContract = new ERC1155TL(false);
        ticketContract.initialize(
            "Ticket", "TICKET", "", address(this), 1000, address(this), new address[](0), true, address(0)
        );

        // create ticket
        address[] memory recipients = new address[](1);
        recipients[0] = address(420);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        ticketContract.createToken("https://ticket-contract.com/ticket", recipients, amounts);

        // deploy nft contract implementation
        nftContract = new ERC721TL(true);

        // add implementation to the universal deployer
        deployer.addDeployableContract(
            "ERC721TL", TLUniversalDeployer.ContractVersion({id: "3.2.0", implementation: address(nftContract)})
        );

        // deploy game implementation
        gameImplementation = address(new Game(true));

        // deploy artcade
        artcade = new Artcade(address(this));

        // set artcade as mint contract for tickets
        address[] memory mintContracts = new address[](1);
        mintContracts[0] = address(artcade);
        ticketContract.setApprovedMintContracts(mintContracts, true);

        // setup artcade
        artcade.updateSettings(
            Artcade.Settings({
                pricePerGame: 0,
                maxTicketPerGame: maxTickets,
                ticketAddress: address(ticketContract),
                ticketTokenId: 1,
                protocolFeeRecipient: address(artcade),
                protocolFeeBps: 0,
                weth: weth,
                gameImplementationAddress: gameImplementation,
                universalDeployer: deployer,
                contractType: "ERC721TL",
                versionIndex: 0
            })
        );
    }

    function test_updateSettings(address hacker) public {
        vm.assume(hacker != address(this));

        Artcade.Settings memory settings = Artcade.Settings({
            pricePerGame: 3,
            maxTicketPerGame: 3,
            ticketAddress: address(1),
            ticketTokenId: 2,
            protocolFeeRecipient: address(hacker),
            protocolFeeBps: 100,
            weth: address(2),
            gameImplementationAddress: address(3),
            universalDeployer: TLUniversalDeployer(address(4)),
            contractType: "ERC1155TL",
            versionIndex: 1
        });

        // make sure hacker can't access and it reverts with proper error
        vm.prank(hacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, hacker));
        artcade.updateSettings(settings);

        // make sure owner can access and it succeeds
        vm.prank(address(this));
        artcade.updateSettings(settings);

        Artcade.Settings memory newSettings = artcade.getSettings();
        assertEq(newSettings.pricePerGame, settings.pricePerGame);
        assertEq(newSettings.maxTicketPerGame, settings.maxTicketPerGame);
        assertEq(newSettings.ticketAddress, settings.ticketAddress);
        assertEq(newSettings.ticketTokenId, settings.ticketTokenId);
        assertEq(newSettings.protocolFeeRecipient, settings.protocolFeeRecipient);
        assertEq(newSettings.protocolFeeBps, settings.protocolFeeBps);
        assertEq(newSettings.weth, settings.weth);
        assertEq(newSettings.gameImplementationAddress, settings.gameImplementationAddress);
        assertEq(address(newSettings.universalDeployer), address(settings.universalDeployer));
        assertEq(keccak256(bytes(newSettings.contractType)), keccak256(bytes(settings.contractType)));
        assertEq(newSettings.versionIndex, settings.versionIndex);
    }

    function test_setTicketAdjustment(address hacker) public {
        vm.assume(hacker != address(this));

        // make sure hacker can't access and it reverts with proper error
        vm.prank(hacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, hacker));
        artcade.setTicketAdjustment(address(1), 1);

        // make sure owner can access but it throws for invalid game
        vm.prank(address(this));
        artcade.setTicketAdjustment(address(1), 1);

        // get game info
        Artcade.GameInfo memory gameInfo = artcade.getGame(address(1));
        assertEq(gameInfo.ticketAdjustment, 1);
    }

    function test_createGame(address gameDev, address signer_, uint256 maxScore, address feeRecipient) public {
        vm.assume(gameDev != address(0));

        // make sure the game creation fails if the game address isn't an admin on the nft contract
        vm.prank(gameDev);
        vm.expectRevert(Artcade.GameNotNftAdmin.selector);
        artcade.createGame(
            "test",
            "https://test.com",
            signer_,
            maxScore,
            feeRecipient,
            abi.encodeWithSignature(
                "initialize(string,string,string,address,uint256,address,address[],bool,address,address)",
                "game player token",
                "GPT",
                "",
                gameDev,
                1000,
                gameDev,
                new address[](0),
                true,
                address(0),
                address(0)
            )
        );

        // create game
        address gameAddress = artcade.predictGameAddress("test", gameDev);
        address[] memory admins = new address[](1);
        admins[0] = gameAddress;

        vm.prank(gameDev);
        vm.expectEmit(true, true, true, true);
        emit Artcade.GameCreated(gameDev, gameAddress);
        artcade.createGame(
            "test",
            "https://test.com",
            signer,
            maxScore,
            feeRecipient,
            abi.encodeWithSignature(
                "initialize(string,string,string,address,uint256,address,address[],bool,address,address)",
                "game player token",
                "GPT",
                "",
                gameDev,
                1000,
                gameDev,
                admins,
                true,
                address(0),
                address(0)
            )
        );

        // ensure game data matches expectation
        Artcade.GameInfo memory game = artcade.getGame(gameAddress);
        assertTrue(game.created);
        assertEq(game.ticketAdjustment, 0);
    }

    function test_dispenseTickets(uint128 ticketAdjustment, uint256 score, address player) public {
        vm.assume(player != address(0));
        vm.assume(player.code.length == 0);

        if (score > 1000) {
            score %= 1000;
        }

        if (ticketAdjustment > 2000) {
            ticketAdjustment %= 2000;
        }

        // call from not a game
        vm.prank(player);
        vm.expectRevert(Artcade.NotAllowed.selector);
        artcade.dispenseTickets(player, maxTickets);

        // create game
        address gameAddress = artcade.predictGameAddress("test", address(this));
        address[] memory admins = new address[](1);
        admins[0] = gameAddress;

        vm.expectEmit(true, true, true, true);
        emit Artcade.GameCreated(address(this), gameAddress);
        artcade.createGame(
            "test",
            "https://test.com",
            signer,
            1000,
            address(this),
            abi.encodeWithSignature(
                "initialize(string,string,string,address,uint256,address,address[],bool,address,address)",
                "game player token",
                "GPT",
                "",
                address(this),
                1000,
                address(this),
                admins,
                true,
                address(0),
                address(0)
            )
        );

        Game game = Game(gameAddress);

        // register player
        vm.prank(player);
        game.registerPlayer(player);

        // deploy signer contract
        GameEIP712 signerContract = new GameEIP712("test", gameAddress);

        // submit score
        bytes memory signature = signerContract.signScore(privateKey, player, score, bytes32(0));
        uint256 ticketAmount = maxTickets * score / 1000;
        vm.prank(player);
        vm.expectEmit(true, true, true, true);
        emit Artcade.TicketsDispensed(gameAddress, player, ticketAmount);
        game.submitScore(player, score, bytes32(0), signature);

        // ensure tickets are dispensed
        assertEq(ticketContract.balanceOf(player, 1), ticketAmount);

        // add ticket adjustment to the game
        artcade.setTicketAdjustment(gameAddress, ticketAdjustment);

        // submit score again
        signature = signerContract.signScore(privateKey, player, score, bytes32(uint256(1)));
        uint256 secondTicketAmount = ticketAmount;
        if (uint256(ticketAdjustment) > ticketAmount) {
            secondTicketAmount = 0;
        } else {
            secondTicketAmount -= ticketAdjustment;
        }
        vm.expectEmit(true, true, true, true);
        emit Artcade.TicketsDispensed(gameAddress, player, secondTicketAmount);
        game.submitScore(player, score, bytes32(uint256(1)), signature);

        // ensure adjusted tickets are dispensed
        assertEq(ticketContract.balanceOf(player, 1), ticketAmount + secondTicketAmount);
    }
}
