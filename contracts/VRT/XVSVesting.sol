pragma solidity ^0.5.16;

import "../Utils/IBEP20.sol";
import "../Utils/SafeBEP20.sol";

contract XVSVesting {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    uint256 private constant TOTAL_VESTING_TIME = 360 * 24 * 60 * 60;

    /// @notice Administrator for this contract
    address public admin;

    /// @notice Pending administrator for this contract
    address public pendingAdmin;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice The XVS TOKEN!
    IBEP20 public xvs;

    /// @notice VRTConversion Contract Address
    address public vrtConversionAddress;

    /// @notice decimal precision for XVS
    uint256 public xvsDecimalsMultiplier = 10**18;

    event VestedTokensClaimed(address recipient, uint256 amountClaimed);

    /// @notice Emitted when pendingAdmin is accepted, which means admin is updated
    event NewAdmin(address oldAdmin, address newAdmin);

    /// @notice Emitted when pendingAdmin is changed
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /// @notice Emitted when vrtConversionAddress is set
    event VRTConversionSet(address vrtConversionAddress);

    /// @notice Emitted when XVS is deposited for vesting
    event XVSVested(
        address indexed recipient,
        uint256 startTime,
        uint256 amount,
        uint256 withdrawnAmount
    );

    /// @notice Emitted when XVS is withdrawn by recipient
    event XVSWithdrawn(address recipient, uint256 amount);

    struct VestingRecord {
        address recipient;
        uint256 startTime;
        uint256 amount;
        uint256 withdrawnAmount;
    }

    mapping(address => VestingRecord[]) public vestings;

    mapping(address => uint256) public numberOfVestings;

    modifier nonZeroAddress(address _address) {
        require(_address != address(0), "Address cannot be Zero");
        _;
    }

    constructor(address _xvsAddress) public nonZeroAddress(_xvsAddress) {
        admin = msg.sender;
        xvs = IBEP20(_xvsAddress);
        _notEntered = true;
    }

    function _setVRTConversion(address _vrtConversionAddress)
        external
        onlyAdmin
        nonZeroAddress(_vrtConversionAddress)
    {
        vrtConversionAddress = _vrtConversionAddress;
        emit VRTConversionSet(_vrtConversionAddress);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    modifier onlyVrtConverter() {
        require(
            msg.sender == vrtConversionAddress,
            "only VRTConversion Address can call the function"
        );
        _;
    }

    /**
     * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @param newPendingAdmin New pending admin.
     */
    function _setPendingAdmin(address newPendingAdmin) external {
        // Check caller = admin
        require(msg.sender == admin, "Only Admin can set the PendingAdmin");

        // Save current value, if any, for inclusion in log
        address oldPendingAdmin = pendingAdmin;

        // Store pendingAdmin with value newPendingAdmin
        pendingAdmin = newPendingAdmin;

        // Emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin)
        emit NewPendingAdmin(oldPendingAdmin, newPendingAdmin);
    }

    /**
     * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
     * @dev Admin function for pending admin to accept role and update admin
     */
    function _acceptAdmin() external {
        // Check caller is pendingAdmin
        require(msg.sender == pendingAdmin, "Only PendingAdmin can accept as Admin");

        // Save current values for inclusion in log
        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;

        // Store admin with value pendingAdmin
        admin = pendingAdmin;

        // Clear the pending value
        pendingAdmin = address(0);

        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);
    }

    modifier vestingExistCheck(address recipient) {
        require(
            numberOfVestings[recipient] > 0,
            "recipient doesnot have any vestingRecord"
        );

        _;
    }

    function deposit(address recipient, uint depositAmount) external onlyVrtConverter
        nonReentrant
        nonZeroAddress(recipient) {
        require(depositAmount > 0, "Deposit amount must be non-zero");

        VestingRecord[] storage vestingsOfRecipient = vestings[recipient];

        VestingRecord memory vesting = VestingRecord({
            recipient: recipient,
            startTime: getCurrentTime(),
            amount: depositAmount,
            withdrawnAmount: 0
        });

        vestingsOfRecipient.push(vesting);
        numberOfVestings[recipient] = numberOfVestings[recipient].add(1);

        emit XVSVested(
            recipient,
            vesting.startTime,
            vesting.amount,
            vesting.withdrawnAmount
        );
    }

    function withdraw() external vestingExistCheck(msg.sender) {
        require(
            vrtConversionAddress != address(0),
            "VRT-Conversion Address is not set"
        );

        address recipient = msg.sender;
        VestingRecord[] storage vestingsOfRecipient = vestings[recipient];
        uint256 vestingCount = numberOfVestings[recipient];
        uint256 totalWithdrawableAmount = 0;

        for(uint i = 0; i < vestingCount; i++) {
            VestingRecord storage vesting = vestingsOfRecipient[i];
            (uint256 vestedAmount, uint256 toWithdraw) = calculateWithdrawableAmount(vesting.amount, vesting.startTime, vesting.withdrawnAmount);
            if(toWithdraw > 0){
                totalWithdrawableAmount = totalWithdrawableAmount.add(toWithdraw);
                vesting.withdrawnAmount = vesting.withdrawnAmount.add(toWithdraw);
            }
        }

       if(totalWithdrawableAmount > 0){
           uint256 xvsBalance = xvs.balanceOf(address(this));
           require(xvsBalance >= totalWithdrawableAmount, "Insufficient XVS for withdrawal");
           emit XVSWithdrawn(recipient, totalWithdrawableAmount);
           xvs.safeTransfer(recipient, totalWithdrawableAmount);
       }
    }

    function getWithdrawableAmount(address recipient) view public nonZeroAddress(recipient) 
    returns (uint256 totalWithdrawableAmount, uint256 totalVestedAmount, uint256 totalWithdrawnAmount)
    {
        VestingRecord[] memory vestingsOfRecipient = vestings[recipient];
        uint256 vestingCount = numberOfVestings[recipient];

        for(uint i = 0; i < vestingCount; i++) {
            VestingRecord memory vesting = vestingsOfRecipient[i];
            (uint256 vestedAmount, uint256 toWithdraw) = calculateWithdrawableAmount(vesting.amount, vesting.startTime, vesting.withdrawnAmount);
            totalVestedAmount = totalVestedAmount.add(vestedAmount);
            totalWithdrawableAmount = totalWithdrawableAmount.add(toWithdraw);
            totalWithdrawnAmount = totalWithdrawnAmount.add(vesting.withdrawnAmount);
        }

        return (totalWithdrawableAmount, totalVestedAmount, totalWithdrawnAmount);
    }

    function calculateWithdrawableAmount(uint256 amount, uint256 vestingStartTime, uint256 withdrawnAmount)
      view internal returns (uint256, uint256) {
        uint256 vestedAmount = calculateVestedAmount(amount, vestingStartTime, getCurrentTime());
        uint toWithdraw = vestedAmount.sub(withdrawnAmount);
        return (vestedAmount, toWithdraw);
    }

    function getVestedAmount(address recipient) view public nonZeroAddress(recipient) returns (uint256) {

        VestingRecord[] memory vestingsOfRecipient = vestings[recipient];
        uint256 vestingCount = numberOfVestings[recipient];
        uint256 totalVestedAmount = 0;
        uint256 currentTime = getCurrentTime();

        for(uint i = 0; i < vestingCount; i++) {
            VestingRecord memory vesting = vestingsOfRecipient[i];
            uint256 vestedAmount = calculateVestedAmount(vesting.amount, vesting.startTime, currentTime);
            totalVestedAmount = totalVestedAmount.add(vestedAmount);
        }

        return totalVestedAmount;
    }

    function calculateVestedAmount(uint256 vestingAmount, uint256 vestingStartTime, uint256 currentTime) internal view returns (uint256) {
        if (currentTime < vestingStartTime) {
            return 0;
        } else if (currentTime > vestingStartTime.add(TOTAL_VESTING_TIME)) {
            return vestingAmount;
        } else {
            return (vestingAmount.mul(currentTime.sub(vestingStartTime))).div(TOTAL_VESTING_TIME);
        }
    }

   function getCurrentTime() public view returns (uint256) {
      return block.timestamp;
   }

    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

}
