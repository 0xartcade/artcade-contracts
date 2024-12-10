// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {Ownable} from "@openzeppelin-contracts-5.0.2/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts-5.0.2/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin-contracts-5.0.2/proxy/Clones.sol";
import {IERC1155TL} from "tl-creator-contracts-3.3.1/erc-1155/IERC1155TL.sol";
import {TLUniversalDeployer} from "tl-universal-deployer-1.0.1/TLUniversalDeployer.sol";
import {ERC721TL} from "tl-creator-contracts-3.3.1/erc-721/ERC721TL.sol";
import {Game} from "./Game.sol";

/// @title Artacde.sol
/// @notice Registry of games & ticket dispenser which comprises the Artcade
/// @author mpeyfuss
contract Artcade is Ownable, ReentrancyGuard {
    //////////////////////////////////////////////////////
    /// STRUCTS
    //////////////////////////////////////////////////////

    struct Settings {
        uint256 pricePerGame;
        uint256 maxTicketPerGame;
        address ticketAddress;
        uint256 ticketTokenId;
        address protocolFeeRecipient;
        uint256 protocolFeeBps;
        address weth;
        address gameImplementationAddress;
        TLUniversalDeployer universalDeployer;
        string contractType;
        uint256 versionIndex;
    }

    struct GameInfo {
        bool created;
        uint128 ticketAdjustment; // some games may be easier than others so an offset may be needed to move the distribution curve the the left
    }

    //////////////////////////////////////////////////////
    /// STATE VARIABLES
    //////////////////////////////////////////////////////

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 public constant BASIS = 10_000;
    Settings private _settings;
    uint256 private _game;
    mapping(address => GameInfo) private _games;

    //////////////////////////////////////////////////////
    /// ERRORS
    //////////////////////////////////////////////////////

    error GameNotNftAdmin();
    error NotAllowed();

    //////////////////////////////////////////////////////
    /// EVENTS
    //////////////////////////////////////////////////////

    event NewSettings(address indexed sender, Settings oldSettings, Settings newSettings);
    event GameCreated(address indexed sender, address indexed gameAddress);
    event GameTicketsAdjusted(address indexed sender, address indexed gameAddress, uint256 indexed ticketAdjustment);
    event TicketsDispensed(address indexed gameAddress, address indexed player, uint256 indexed amount);

    //////////////////////////////////////////////////////
    /// MODIFIERS
    //////////////////////////////////////////////////////

    modifier onlyGame() {
        GameInfo memory game = _games[msg.sender];
        if (!game.created) revert NotAllowed();
        _;
    }

    //////////////////////////////////////////////////////
    /// CONSTRUCTOR
    //////////////////////////////////////////////////////

    constructor(address initOwner) Ownable(initOwner) ReentrancyGuard() {}

    //////////////////////////////////////////////////////
    /// GAME FUNCTIONS
    //////////////////////////////////////////////////////

    /// @notice Function to create a game
    /// @dev Requirements
    ///      - anyone can create
    ///      - deploys the leaderboard contract (ERC721TLMutable) that the game uses
    ///      - msg.sender is the game & leaderboard owner
    ///      - ERC-1167 minimal proxies are used
    function createGame(
        string calldata name,
        string calldata baseUri,
        address signer,
        uint256 maxScore,
        address feeRecipient,
        bytes calldata nftInitializationCode
    ) external nonReentrant {
        // create game, with the salt being the name
        bytes32 salt = keccak256(abi.encode(name, msg.sender));
        address gameAddress = Clones.cloneDeterministic(_settings.gameImplementationAddress, salt);

        // deploy nft with the initialization code
        address nftAddress = _settings.universalDeployer.predictDeployedContractAddress(
            address(this), _settings.contractType, nftInitializationCode, _settings.versionIndex
        );
        _settings.universalDeployer.deploy(_settings.contractType, nftInitializationCode, _settings.versionIndex);

        // make sure the game is an admin on the nft contract
        if (!ERC721TL(nftAddress).hasRole(ADMIN_ROLE, gameAddress)) revert GameNotNftAdmin();

        // initialize game
        Game(gameAddress).initialize(msg.sender, name, baseUri, nftAddress, signer, maxScore, feeRecipient);

        // store game
        _games[gameAddress] = GameInfo({created: true, ticketAdjustment: 0});

        emit GameCreated(msg.sender, gameAddress);
    }

    /// @notice Function used by games to dispense tickets
    /// @dev Requirements
    ///      - `amount` cannot be great than the max tickets allowed by the _settings
    ///      - applies any game specific ticket adjustment
    ///      - only games can call this function
    function dispenseTickets(address player, uint256 amount) external onlyGame nonReentrant {
        // cache data
        Settings memory s = _settings;
        GameInfo memory game = _games[msg.sender];

        // if the game tickets have an adjustment, apply that to `amount`
        if (game.ticketAdjustment > amount) {
            amount = 0;
        } else {
            amount -= uint256(game.ticketAdjustment);
        }

        // dispense tickets if greater than 0
        if (amount > 0) {
            address[] memory recipients = new address[](1);
            recipients[0] = player;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = amount;

            IERC1155TL(s.ticketAddress).externalMint(s.ticketTokenId, recipients, amounts);
        }

        emit TicketsDispensed(msg.sender, player, amount);
    }

    //////////////////////////////////////////////////////
    /// ADMIN FUNCTIONS
    //////////////////////////////////////////////////////

    /// @notice Function to update the _settings
    function updateSettings(Settings calldata settings_) external onlyOwner {
        Settings memory oldSettings = _settings;
        _settings = settings_;

        emit NewSettings(msg.sender, oldSettings, settings_);
    }

    /// @notice Function to set a ticket adjustment for a particular game
    /// @dev This should only be used if a game is too easy, in order to make things fair. Ideally it's never used.
    function setTicketAdjustment(address gameAddress, uint128 ticketAdjustment_) external onlyOwner {
        _games[gameAddress].ticketAdjustment = ticketAdjustment_;

        emit GameTicketsAdjusted(msg.sender, gameAddress, ticketAdjustment_);
    }

    //////////////////////////////////////////////////////
    /// VIEW FUNCTIONS
    //////////////////////////////////////////////////////

    /// @notice View function to get settings
    function getSettings() external view returns (Settings memory) {
        return _settings;
    }

    /// @notice View function to predict game address
    function predictGameAddress(string calldata name, address sender) external view returns (address) {
        return
            Clones.predictDeterministicAddress(_settings.gameImplementationAddress, keccak256(abi.encode(name, sender)));
    }

    /// @notice View function to get game information directly
    function getGame(address gameAddress) external view returns (GameInfo memory) {
        return _games[gameAddress];
    }
}
