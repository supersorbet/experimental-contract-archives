pragma solidity ^0.8.19;
// SPDX-License-Identifier: UNLICENSED

import "./ERC1155Receiver.sol";
import "./IERC1155.sol";
import "./SafeMath.sol";


contract ERC1155Holder is ERC1155Receiver {
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

contract ContractEvents {
    //when user stakes nfts
    event NFTstake(address indexed user, uint256 value);

    //when user unstakes nfts
    event NFTunstake(address indexed user, uint256 value);

    //when a user distributes rewards tokens
    event TokenDistribution(address indexed user, uint256 value);
    //when a user claims rewards tokens
    event TokenClaim(address indexed user, uint256 value);

    //when contract stakes tokens
    event TokenStake(address indexed user, uint256 value);

    //when contract compounds tokens
    event TokenCompound(address indexed user, uint256 value);

    //when contract burns tokens
    event TokenBurn(address indexed user, uint256 value);
}

contract SlugStakingNFT is ContractEvents, ERC1155Holder {
    using SafeMath for uint256;

    bool private sync;

    //protects against potential reentrancy
    modifier synchronized() {
        require(!sync, "Sync lock");
        sync = true;
        _;
        sync = false;
    }

    // Contract deployer
    address dev;
    // The address of the SLUG contract.
    address slugContract = ; 
    //The address of the Genesis NFT contract.
    address nftContract = ; 

    //Array of active stakers
    address[] public activeStakers; // Array count (max 32)
    // Mapping from user address to number of staked NFTs.
    mapping(address => uint256) public usersStakedNFTs;
    // Mapping from user to amount of rewards available to claim.
    mapping(address => uint256) public stakerRewards;
    // Yield data
    uint256 public totalStakedNfts;
    uint256 public availableToBurn;
    uint256 public availableToCompound;

    constructor() {
        dev = msg.sender;
    }

    // Stakes an NFT.
    function stakeNFT(uint256 _nfts) external synchronized {
        // Ensure the contract has been approved to receive the NFT.
        require(
            IERC1155(nftContract).isApprovedForAll(msg.sender, address(this)),
            "Contract has not been approved to receive the NFT."
        );
        require(_nfts > 0, "Define amount of Genesis NFTs to stake");
        // Do not allow yield dist on first ever NFT stake.
        if (totalStakedNfts > 0) {
            distributeYield();
        }
        //Add user to active array if not already.
        if (usersStakedNFTs[msg.sender] == 0) {
            activeStakers.push(msg.sender);
        }
        // Increase value of total NFTs staked at current
        totalStakedNfts += _nfts;
        // Increase value of NFTs staked by user
        usersStakedNFTs[msg.sender] += _nfts;
        // Transfer the appropriate amount of NFTs to the contract.
        IERC1155(nftContract).safeTransferFrom(
            msg.sender,
            address(this),
            1,
            _nfts,
            ""
        );
        emit NFTstake(msg.sender, _nfts);
    }

    // Unstakes an NFT.
    function unstakeNFT(uint256 _nfts) external synchronized {
        require(_nfts > 0, "Define amount of Genesis NFTs to unstake");
        // Ensure the caller cannot unstake NFTs they do not own.
        require(
            usersStakedNFTs[msg.sender] >= _nfts,
            "Input amount is larger than users staked NFTs."
        );
        distributeYield();
        // Decrease value of total NFTs staked at current
        totalStakedNfts -= _nfts;
        // Decrease value of NFTs staked by user
        usersStakedNFTs[msg.sender] -= _nfts;
        // Remove user from active staker array if NFT stake count 0.
        if (usersStakedNFTs[msg.sender] == 0) {
            for (uint256 i; i < activeStakers.length; i++) {
                // Find staker
                if (activeStakers[i] == msg.sender) {
                    // Remove staker
                    delete activeStakers[i];
                    removeElement(i);
                    break;
                }
            }
        }
        // Send the NFT/s to user
        IERC1155(nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            1,
            _nfts,
            ""
        );
        if (stakerRewards[msg.sender] > 0) {
            claimYield();
        }
        emit NFTunstake(msg.sender, _nfts);
    }

    // Reset staker array
    function removeElement(uint256 index) internal {
        activeStakers[index] = activeStakers[activeStakers.length - 1];
        activeStakers.pop();
    }

    // Distributes the yield accrued from the NFT staking contract.
    function DistributeYield() external synchronized {
        distributeYield();
    }

    function distributeYield() internal {
        // Calculate the total yield.
        uint256 yield = ERC20(slugContract).calcStakingRewards(address(this));
        // Calculate distributions
        if (yield > 0) {
            uint256 distributable = yield.mul(85).div(100); //85% to stakers
            uint256 yieldPerNft = distributable.div(totalStakedNfts); //equal yield per Genesis NFT
            availableToBurn += yield.mul(10).div(100); //10% burn to raise NFT staking APY
            availableToCompound += yield.mul(5).div(100); //5% compound to compound stake while maintaining APY rise(add to stake)
            // Distribute the yield equally among all staked NFTs
            for (uint256 i = 0; i < activeStakers.length; i++) {
                stakerRewards[activeStakers[i]] += yieldPerNft.mul(
                    usersStakedNFTs[activeStakers[i]]
                );
            }
            ERC20(slugContract).ClaimStakeRewards();
            emit TokenDistribution(msg.sender, yield);
        }
    }

    //Claims the yield allocated for an individual user
    function ClaimYield() external synchronized {
        claimYield();
    }

    function claimYield() internal {
        uint256 yield = stakerRewards[msg.sender];
        stakerRewards[msg.sender] = 0;
        require(yield > 0, "Nothing to claim");
        ERC20(slugContract).transfer(msg.sender, yield);
        emit TokenClaim(msg.sender, yield);
    }

    //Adds SLUG from callers wallet to the NFT contract stake, also claims any rewards
    function add2Stake(uint256 _amt) external synchronized {
        //send tokens from user wallet to NFT contract (approval needed)
        require(
            ERC20(slugContract).transferFrom(msg.sender, address(this), _amt)
        );
        distributeYield();
        //stake _amt to SLUG contract on behalf of NFT contract (dev is ref)
        ERC20(slugContract).StakeTokens(_amt, dev);
        emit TokenStake(msg.sender, _amt);
    }

    //compounds allocated SLUG into the NFT contract stake
    function CompoundySlugs() external synchronized {
        uint256 toCompound = availableToCompound;
        require(availableToCompound > 0, "Nothing to compound");
        availableToCompound = 0;
        distributeYield();
        // Stake tokens to SLUG contract on behalf of NFT contract, also claims any rewards (dev is ref)
        ERC20(slugContract).StakeTokens(toCompound, dev);
        emit TokenCompound(msg.sender, toCompound);
    }

    // Burn allocated SLUG on behalf of NFT contract to increase NFT staking APY
    function incinerateAllocatedTokens() external synchronized {
         uint256 toBurn = availableToBurn;
        require(availableToBurn > 0, "Nothing to burn");
        availableToBurn = 0;
        distributeYield();
        ERC20(slugContract).BurnSlug(toBurn);
        emit TokenBurn(msg.sender, toBurn);
    }

    function getUserStakedNFTs(address _staker)
        external
        view
        returns (uint256)
    {
        return usersStakedNFTs[_staker];
    }
}
