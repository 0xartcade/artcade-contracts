// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable-5.0.2/access/OwnableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin-contracts-upgradeable-5.0.2/utils/cryptography/EIP712Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin-contracts-upgradeable-5.0.2/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin-contracts-upgradeable-5.0.2/utils/PausableUpgradeable.sol";
import {Strings} from "@openzeppelin-contracts-5.0.2/utils/Strings.sol";
import {ECDSA} from "@openzeppelin-contracts-5.0.2/utils/cryptography/ECDSA.sol";
import {TransferHelper} from "tl-sol-tools-3.1.4/payments/TransferHelper.sol";
import {ERC721TL} from "tl-creator-contracts-3.3.1/erc-721/ERC721TL.sol";
import {Artcade} from "./Artcade.sol";

/// @title Game.sol
/// @notice Implementation contract dictating how games work in the Artcade
/// @author mpeyfuss
contract Game is
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable,
    TransferHelper
{
    //////////////////////////////////////////////////////
    /// STRUCTS & TYPES
    //////////////////////////////////////////////////////

    using Strings for uint256;

    struct Settings {
        string name;
        string baseUri;
        address signer;
        uint256 maxScore;
        address feeRecipient;
    }

    //////////////////////////////////////////////////////
    /// STORAGE VARIABLES
    //////////////////////////////////////////////////////

    uint256 public constant BASIS = 10_000;
    Settings public settings;
    Artcade public artcade;
    ERC721TL public nftContract;
    mapping(address => uint256) private _highScores; // player -> high score (stores high score for leaderboard)
    mapping(address => mapping(bytes32 => bool)) private _noncesUsed; // player -> nonce -> bool if used (replay protection)
    mapping(address => uint256) private _playerNfts; // player -> nft token id (ensures player only has one nft)

    //////////////////////////////////////////////////////
    /// ERRORS
    //////////////////////////////////////////////////////

    error NonceUsed();
    error PlayerAlreadyRegistered();
    error PlayerNotRegistered();
    error PlayerDoesNotOwnPlayerNft();
    error InvalidSignature();
    error InvalidPayment();
    error InvalidScore();

    //////////////////////////////////////////////////////
    /// EVENTS
    //////////////////////////////////////////////////////

    event NewSettings(address indexed sender, Settings oldSettings, Settings newSettings);
    event PlayerRegistered(address indexed player, uint256 indexed playerTokenId);
    event NewHighScore(address indexed player, uint256 indexed playerTokenId, uint256 indexed highScore);

    //////////////////////////////////////////////////////
    /// CONSTRUCTOR
    //////////////////////////////////////////////////////

    constructor(bool disable) {
        if (disable) _disableInitializers();
    }

    //////////////////////////////////////////////////////
    /// INITIALIZATION
    //////////////////////////////////////////////////////

    /// @notice Function to initialize the minimal proxy
    function initialize(
        address owner_,
        string calldata name_,
        string calldata baseUri_,
        address nftAddress_,
        address signer_,
        uint256 maxScore_,
        address feeRecipient_
    ) external initializer {
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        __Pausable_init();
        __EIP712_init(name_, "1");

        Settings memory settings_ = Settings({
            name: name_,
            baseUri: baseUri_,
            signer: signer_,
            maxScore: maxScore_,
            feeRecipient: feeRecipient_
        });
        _updateSettings(settings_);

        nftContract = ERC721TL(nftAddress_); // immutable, don't let people change it out
        artcade = Artcade(msg.sender); // Artcade deploys and initializes this contract, immutable
    }

    //////////////////////////////////////////////////////
    /// GAME FUNCTIONS
    //////////////////////////////////////////////////////

    /// @notice Function for players to enroll in the game
    /// @dev Free but requires that they have not already minted
    /// @dev Can be batched with multicall
    function registerPlayer(address player) external whenNotPaused nonReentrant {
        // cache data
        Settings memory s = settings;

        // check pre-condition
        if (_playerNfts[player] != 0) revert PlayerAlreadyRegistered();

        // get next token id
        uint256 tokenId = nftContract.totalSupply() + 1;

        // store
        _playerNfts[player] = tokenId;

        // mint token
        nftContract.mint(player, string(abi.encodePacked(s.baseUri, "/", tokenId.toString())));

        emit PlayerRegistered(player, tokenId);
    }

    /// @notice Function to submit a score
    /// @dev Requirements
    ///      - nonce can't be used already
    ///      - player must have minted and still own their player nft for this game
    ///      - signature must be valid
    ///      - enough eth must be sent in the call
    ///      - if the score is their new high score, save it onchain
    /// @dev This can be batched with multicall or submitted cross-chain
    function submitScore(address player, uint256 score, bytes32 nonce, bytes calldata signature)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        // settings
        Settings memory s = settings;

        // make sure nonce isn't used
        if (_noncesUsed[player][nonce]) revert NonceUsed();

        // make sure score doesn't exceed max score
        if (score > s.maxScore) revert InvalidScore();

        // make sure user still owns their nft that represents their participation in the game
        uint256 tokenId = _playerNfts[player];
        if (tokenId == 0) revert PlayerNotRegistered();
        if (nftContract.ownerOf(tokenId) != player) revert PlayerDoesNotOwnPlayerNft();

        // verify signature
        bytes32 scoreHash = _hashScoreData(player, score, nonce);
        bytes32 digest = _hashTypedDataV4(scoreHash);
        if (s.signer != ECDSA.recover(digest, signature)) revert InvalidSignature();

        // store nonce
        _noncesUsed[player][nonce] = true;

        // store score if new high score
        if (score > _highScores[player]) {
            _highScores[player] = score;
            emit NewHighScore(player, tokenId, score);
        }

        // receive payment & dispense tickets
        _settleUp(s, player, score);
    }

    //////////////////////////////////////////////////////
    /// ADMIN FUNCTIONS
    //////////////////////////////////////////////////////

    function updateSettings(Settings memory settings_) external onlyOwner {
        _updateSettings(settings_);
    }

    function setPaused(bool pause) external onlyOwner {
        if (pause) {
            _pause();
        } else {
            _unpause();
        }
    }

    //////////////////////////////////////////////////////
    /// VIEW FUNCTIONS
    //////////////////////////////////////////////////////

    /// @notice Function to get the token id for a player's NFT
    function getPlayerNft(address player) external view returns (uint256) {
        return _playerNfts[player];
    }

    /// @notice Function get a player's high score
    function getPlayerHighScore(address player) external view returns (uint256) {
        return _highScores[player];
    }

    //////////////////////////////////////////////////////
    /// INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////

    /// @notice Internal function to update settings
    function _updateSettings(Settings memory settings_) private {
        Settings memory oldSettings = settings;
        settings = settings_;

        emit NewSettings(msg.sender, oldSettings, settings_);
    }

    /// @notice Internal function to hash the struct for EIP-712
    function _hashScoreData(address player, uint256 score, bytes32 nonce) private pure returns (bytes32) {
        return keccak256(
            abi.encode(keccak256("VerifiedScore(address player,uint256 score,bytes32 nonce)"), player, score, nonce)
        );
    }

    /// @notice Internal function to transfer funds and dispense tickets
    function _settleUp(Settings memory s, address player, uint256 score) private {
        // ensure payment
        Artcade.Settings memory artcadeSettings = artcade.getSettings();
        if (msg.value != artcadeSettings.pricePerGame) revert InvalidPayment();

        // transfer ETH
        uint256 protocolFee = msg.value * artcadeSettings.protocolFeeBps / BASIS;
        _safeTransferETH(artcadeSettings.protocolFeeRecipient, protocolFee, artcadeSettings.weth);
        _safeTransferETH(s.feeRecipient, msg.value - protocolFee, artcadeSettings.weth);

        // dispense tickets from Artcade (score)
        uint256 ticketsToDispense = artcadeSettings.maxTicketPerGame * score / s.maxScore;
        artcade.dispenseTickets(player, ticketsToDispense);
    }
}
