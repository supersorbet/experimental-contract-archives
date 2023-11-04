// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Router02.sol";

interface doubleRewardInterface {
    event LpStake(address indexed user, uint256 value, address indexed lpToken);

    event LpUnstake(
        address indexed user,
        uint256 value,
        address indexed lpToken
    );

  /*  event TokenStake(
        address indexed user,
        uint value
    );

    event TokenUnstake(
        address indexed user,
        uint value
    );
  */
    //when a user burns tokens
    event TokenBurn(address indexed user, uint256 value);
}

   /////////////////////////////////////////


contract Cope is IERC20, Ownable, SafeERC20 {
    using SafeMath for uint256;

    using SafeERC20 for Cope;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    address public cakeCOPEETH;

    uint256 public taxRate = 1;
    address public uniswapV2Pair;
    IUniswapV2Router02 public uniswapV2Router;

    mapping(address => uint256) public lpApy;
    uint32 public globalApy = 1000; //    AAAAAAAAAAAAAAA
    uint16 public halvening = 1;
    uint64 public halveningDays = 7;
    uint256 public halveningTimestamp;
    uint256 public stakingApyLimiter = 1;
    uint256 public burnAdjust = 3000;

    uint256 internal constant MINUTESECONDS = 60;
    uint256 internal constant DAYSECONDS = 86400;
    uint256 internal constant MINSTAKEDAYLENGTH = 2;
    uint256 public totalStaked;
    address[] public lpAddresses;
    mapping(address => uint256) public totalLpFrozen;
    mapping(address => uint256[]) public lpFrozenBalances;
    mapping(address => uint256[]) public lpStakeStartTimes;

    uint256 internal _totalSupply;
    string public constant name = "Cope";
    string public constant symbol = "COPEV3";
    uint8 public constant decimals = 18;

    //admin
    address internal constant _P1 = 0x725252Fd175AB01078B86e8D14bBf1E40B56D078;
    bool public isLocked = false;
    bool private sync;

    mapping(address => bool) admins;
    mapping(address => bool) public isPoolActive;
    mapping(address => Farmer) public farmer;

    struct Farmer {
        uint256 stakedBalance;
        uint256 stakeStartTimestamp;
        uint256 totalStakingInterest;
        uint256 totalFarmedCope;
        uint256 totalBurnt;
        uint256 totalReferralBonus;
        address referrer;
        bool activeUser;
    }

    modifier onlyAdmins() {
        require(admins[msg.sender], "not an admin");
        _;
    }

    //protects against potential reentrancy
    modifier synchronized() {
        require(!sync, "Sync lock");
        sync = true;
        _;
        sync = false;
    }

    constructor(uint256 initialTokens) {
        admins[_P1] = true;
        admins[msg.sender] = true;
        halveningTimestamp = block.timestamp;

        mintInitialTokens(initialTokens);
        uniswapV2Router = IUniswapV2Router02(
            0x9a489505a00cE272eAa5e07Dba6491314CaE3796
        );

    }

    function setUniswapV2Router(IUniswapV2Router02 _uniswapV2Router)
        external
        onlyAdmins
    {
        uniswapV2Router = _uniswapV2Router;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount)
        external
        override
        returns (bool)
    {
        _transfer(msg.sender, recipient, amount);

        return true;
    }

    function allowance(address owner, address spender)
        external
        view
        override
        returns (uint256)
    {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount)
        external
        override
        returns (bool)
    {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            msg.sender,
            _allowances[sender][msg.sender].sub(
                amount,
                "ERC20: transfer amount exceeds allowance"
            )
        );
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        external
        returns (bool)
    {
        _approve(
            msg.sender,
            spender,
            _allowances[msg.sender][spender].add(addedValue)
        );
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        external
        returns (bool)
    {
        _approve(
            msg.sender,
            spender,
            _allowances[msg.sender][spender].sub(
                subtractedValue,
                "ERC20: decreased allowance below zero"
            )
        );
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
    require(sender != address(0), "ERC20: transfer from the zero address");
    require(recipient != address(0), "ERC20: transfer to the zero address");

    // check if sell
    if (sender != uniswapV2Pair) {
        // tax on sellsa
        uint256 taxAmount = amount.mul(taxRate).div(100);
        amount = amount.sub(taxAmount);

        // add LP tax
        _balances[uniswapV2Pair] = _balances[uniswapV2Pair].add(taxAmount);
        emit Transfer(sender, uniswapV2Pair, taxAmount);
    }

    _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
    _balances[recipient] = _balances[recipient].add(amount);
    emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        uint256 amt = amount;
        require(account != address(0), "ERC20: mint to the zero address");
        _totalSupply = _totalSupply.add(amt);
        _balances[account] = _balances[account].add(amt);
        emit Transfer(address(0), account, amt);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");
        _balances[account] = _balances[account].sub(
            amount,
            "ERC20: burn amount exceeds balance"
        );
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _burnFrom(address account, uint256 amount) internal {
        _burn(account, amount);
        _approve(
            account,
            msg.sender,
            _allowances[account][msg.sender].sub(
                amount,
                "ERC20: burn amount exceeds allowance"
            )
        );
    }

    function mintInitialTokens(uint256 amount) internal synchronized {
        _mint(_P1, amount);
    }

    function stakeLP(
        uint256 amt,
        uint256 _lpIndex,
        address _referrer
    ) external synchronized {
        require(isPoolActive[lpAddresses[_lpIndex]], "pool not active");
        require(amt > 0, "zero input");
        require(
            lpBalance(lpAddresses[_lpIndex]) >= amt,
            "Error: insufficient balance"
        ); //ensure user has enough funds
        copeCheck();
        if (isHarvestable(msg.sender, _lpIndex)) {
            uint256 interest = calcHarvestRewards(msg.sender, _lpIndex);
            if (interest > 0) {
                harvest(interest);
            }
        }
        //set user active
        farmer[msg.sender].activeUser = true;
        //update balances
        lpFrozenBalances[msg.sender][_lpIndex] = lpFrozenBalances[msg.sender][
            _lpIndex
        ].add(amt);
        totalLpFrozen[lpAddresses[_lpIndex]] = totalLpFrozen[
            lpAddresses[_lpIndex]
        ].add(amt);
        //update timestamp
        lpStakeStartTimes[msg.sender][_lpIndex] = block.timestamp;

        if (_referrer != address(0) && _referrer != msg.sender) {
            if (
                farmer[_referrer].activeUser &&
                farmer[msg.sender].referrer == address(0)
            ) {
                farmer[msg.sender].referrer = _referrer;
            }
        }
        IUniswapV2Pair(lpAddresses[_lpIndex]).transferFrom(
            msg.sender,
            address(this),
            amt
        ); //make transfer
        emit LpStake(msg.sender, amt, lpAddresses[_lpIndex]);
    }

    function unstakeLP(uint256 _lpIndex) external synchronized {
        require(
            lpFrozenBalances[msg.sender][_lpIndex] > 0,
            "Error: unsufficient frozen balance"
        ); //ensure user has enough frozen funds
        uint256 amt = lpFrozenBalances[msg.sender][_lpIndex];
        if (isHarvestable(msg.sender, _lpIndex)) {
            uint256 interest = calcHarvestRewards(msg.sender, _lpIndex);
            if (interest > 0) {
                harvest(interest);
            }
        }
        lpFrozenBalances[msg.sender][_lpIndex] = 0;
        lpStakeStartTimes[msg.sender][_lpIndex] = 0;
        totalLpFrozen[lpAddresses[_lpIndex]] = totalLpFrozen[
            lpAddresses[_lpIndex]
        ].sub(amt);
        IUniswapV2Pair(lpAddresses[_lpIndex]).transfer(msg.sender, amt); //make transfer
        emit LpUnstake(msg.sender, amt, lpAddresses[_lpIndex]);
    }

    function HarvestCope(uint256 _lpIndex) external synchronized {
        require(
            lpFrozenBalances[msg.sender][_lpIndex] > 0,
            "Error: unsufficient lp balance"
        ); //ensure user has enough lp frozen
        uint256 interest = calcHarvestRewards(msg.sender, _lpIndex);
        if (interest > 0) {
            harvest(interest);
            lpStakeStartTimes[msg.sender][_lpIndex] = block.timestamp;
            farmer[msg.sender].totalFarmedCope += interest;
        }
    }

    function harvest(uint256 rewards) internal {
        _mint(msg.sender, rewards);
        uint256 refFee = rewards.div(10);
        if (farmer[msg.sender].referrer != address(0)) {
            _mint(msg.sender, refFee.div(2)); //5% bonus for farmer using reflink
            _mint(farmer[msg.sender].referrer, refFee.div(2)); //5% referrer bonus on all harvests
            farmer[farmer[msg.sender].referrer].totalReferralBonus += refFee
                .div(2);
        }
        _mint(_P1, refFee.mul(6).div(100)); //6% dev fee
    }

    function copeCheck() internal {
        //ensure lpStakeStartTimes is in cope
        if (lpStakeStartTimes[msg.sender].length < lpAddresses.length) {
            for (
                uint256 i = lpStakeStartTimes[msg.sender].length;
                i < lpAddresses.length;
                i++
            ) {
                lpStakeStartTimes[msg.sender].push(0);
            }
        }
        //ensure lpFrozenBalances is in cope
        if (lpFrozenBalances[msg.sender].length < lpAddresses.length) {
            for (
                uint256 i = lpFrozenBalances[msg.sender].length;
                i < lpAddresses.length;
                i++
            ) {
                lpFrozenBalances[msg.sender].push(0);
            }
        }
    }

   
    function NewHalvening() external synchronized {
        require(
            block.timestamp.sub(halveningTimestamp) >=
                DAYSECONDS.mul(halveningDays),
            "cannot call halvening yet"
        );
        halveningDays += 7; //increase period by 1 week every halvening
        halveningTimestamp = block.timestamp;
        halvening = halvening * 2;
    }

    function BurnCope(uint256 amt) external synchronized {
        require(
            farmer[msg.sender].totalBurnt.add(amt) <=
                farmer[msg.sender].totalStakingInterest.mul(burnAdjust),
            "can only burn equivalent of x3 total staking interest"
        );
        require(amt > 0, "value must be greater than 0");
        require(balanceOf(msg.sender) >= amt, "balance too low");
        //burn tokens of user
        _burn(msg.sender, amt);
        farmer[msg.sender].totalBurnt += amt;
        //burn tokens of swap - pamp it
        _balances[cakeCOPEETH] = _balances[cakeCOPEETH].sub(
            amt,
            "ERC20: burn amount exceeds balance"
        );
        _totalSupply = _totalSupply.sub(amt);
        IUniswapV2Pair(cakeCOPEETH).sync();
        emit TokenBurn(msg.sender, amt);
    }


    //returns amount of minutes past since stake start
    function minsPastStakeTime(address _user) public view returns (uint256) {
        if (farmer[_user].stakeStartTimestamp == 0) {
            return 0;
        }
        uint256 minsPast = block
            .timestamp
            .sub(farmer[_user].stakeStartTimestamp)
            .div(MINUTESECONDS);
        if (minsPast >= 1) {
            return minsPast; // returns 0 if under 1 min passed
        } else {
            return 0;
        }
    }

    // 69000000000000000000000000
    
    function calcHarvestRewards(address _user, uint256 _lpIndex)
        public
        view
        returns (uint256)
    {
        return (
            (
                lpFrozenBalances[_user][_lpIndex].mul(globalApy).div(
                    lpApy[lpAddresses[_lpIndex]]
                )
            ).mul(minsPastStakeTime(_user, _lpIndex)).div(halvening)
        );
    }

    //returns amount of minutes past since lp stake start
    function minsPastStakeTime(address _user, uint256 _lpIndex)
        public
        view
        returns (uint256)
    {
        if (lpStakeStartTimes[_user][_lpIndex] == 0) {
            return 0;
        }
        uint256 minsPast = block
            .timestamp
            .sub(lpStakeStartTimes[_user][_lpIndex])
            .div(MINUTESECONDS);
        if (minsPast >= 1) {
            return minsPast; // returns 0 if under 1 min passed
        } else {
            return 0;
        }
    }
    //total LP balances frozen in contract
    function totalFrozenLpBalance(uint256 _lpIndex)
        external
        view
        returns (uint256)
    {
        return totalLpFrozen[lpAddresses[_lpIndex]];
    }

    //COPE balance of caller
    function copeBalance() public view returns (uint256) {
        return balanceOf(msg.sender);
    }

    //LP balance of caller
    function lpBalance(address _lpAddress) public view returns (uint256) {
        return IUniswapV2Pair(_lpAddress).balanceOf(msg.sender);
    }

    //check if user can harvest COPE yet
    function isHarvestable(address _user, uint256 _lpIndex)
        public
        view
        returns (bool)
    {
        if (lpStakeStartTimes[_user][_lpIndex] == 0) {
            return false;
        } else {
            return
                lpStakeStartTimes[_user][_lpIndex].add(MINUTESECONDS) <=
                block.timestamp;
        }
    }

    function setCOPEETHpool(address _lpAddress) external onlyAdmins {
        require(!isLocked, "cannot change native pool");
        cakeCOPEETH = _lpAddress;
    }

    /////// B U R N ////// (or tax fee)

    // function setBurnRate(uint256 newBurnRate) external onlyAdmins {
    // burnRate = newBurnRate;
    // }

    function setTaxRate(uint256 newTaxRate) external onlyAdmins {
        taxRate = newTaxRate;
    }

    function setBurnAdjust(uint256 _v) external onlyAdmins {
        burnAdjust = _v;
    }

    function stakingApyDecrease() external onlyAdmins {
        require(!isLocked, "cannot change staking APY");
        require(
            stakingApyLimiter == 1,
            "cannot decrease staking APY twice, min 4.20%"
        );
        stakingApyLimiter *= 10;
    }

    function setGlobalApy(uint32 _apy) external onlyAdmins {
        require(!isLocked, "cannot change global APY");
        globalApy = _apy;
    }

    function setApy(uint32 _apy, address _lpAddress) external onlyAdmins {
        require(!isLocked, "cannot change token APY");
        lpApy[_lpAddress] = _apy;
    }

    function setPoolActive(address _lpAddress, bool _active)
        external
        onlyAdmins
    {
        require(!isLocked, "cannot change pool status");
        bool _newAddress = true;
        for (uint256 i = 0; i < lpAddresses.length; i++) {
            if (_lpAddress == lpAddresses[i]) {
                _newAddress = false;
                break;
            }
        }
        if (_newAddress) {
            lpAddresses.push(_lpAddress);
        }
        isPoolActive[_lpAddress] = _active;
    }

    function setEmergencyLock() external onlyAdmins {
        isLocked = true;
    }

    //distribute any arbitrary token stuck in the contract via address (does not allow tokens in use by the platform)
    function distributeTokens(address _tokenAddress) external onlyAdmins {
        //ensure token address does not match platform lp tokens
        for (uint256 i = 0; i < lpAddresses.length; i++) {
            require(
                _tokenAddress != lpAddresses[i],
                "this token is vital to the cope.finance ecosystem, you cannot withdraw this token!!!"
            );
        }
        //ensure token address does not match this contract
        require(
            _tokenAddress != address(this),
            "this token is vital to the cope.finance ecosystem, you cannot withdraw this token!!!"
        );
        //create contract
        IERC20 _token = IERC20(_tokenAddress);
        //get balance
        uint256 balance = _token.balanceOf(address(this));
        //distribute
        _token.transfer(_P1, balance.mul(50).div(100));
    }

    
}