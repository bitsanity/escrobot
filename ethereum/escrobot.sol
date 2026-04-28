// SPDX-License-Identifier: MIT

pragma solidity ^0.8.34;

// FORWARD DECLARATIONS -----------------------------------------------------

interface ERC20 {
  function transfer( address to, uint256 value ) external returns (bool);
  function transferFrom( address from, address to, uint256 value )
    external returns (bool);
}

// ADMIN --------------------------------------------------------------------

contract Admin {
  modifier isAdmin {
    require( msg.sender == admin, "must be admin" );
    _;
  }

  event AdminTransferProposed(
    address indexed currentAdmin,
    address indexed pendingAdmin
  );
  event AdminChanged( address indexed oldAdmin, address indexed newAdmin );

  address payable public admin;
  address payable public pendingAdmin;

  constructor() {
    admin = payable(msg.sender);
  }

  function proposeAdmin( address payable _newAdmin ) public isAdmin {
    require( _newAdmin != address(0x0), "null not allowed" );
    pendingAdmin = _newAdmin;
    emit AdminTransferProposed( admin, _newAdmin );
  }

  function acceptAdmin() external {
    require( msg.sender == pendingAdmin, "must be pending admin" );
    address oldAdmin = admin;
    admin = pendingAdmin;
    pendingAdmin = payable(address(0x0));
    emit AdminChanged( oldAdmin, admin );
  }
}

// ==========================================================================
// escrobot.eth is an automated escrow service enabling buyers to pay with
// Ether or any ERC20-compatible token, including but not limited to
// stablecoins).
//
// Normal Scenario:
//
// 1. Seller submits an Order to this contract.
// 2. Buyer pays the Seller's price plus a bond, an amount set by the Seller
//    that motivates the Buyer to confirm delivery and release payment.
// 3. Seller ships and updates this contract with the tracking reference.
// 4. Buyer confirms the shipment has been received.
// 5. This contract releases payment to Seller and returns Buyer's bond
//
// Exceptions/Extras:
//
// a. Seller may cancel an Order not yet paid (Buyer has disappeared)
// b. Buyer may obtain a refund if Seller fails to ship within a
//    Seller-specified timeout in blocks (Seller has disappeared)
// c. Either party may add a plaintext note at any time to resolve issues
// d. If shipment fails, payment will not be released and bond will not be
//    returned unless/until the Buyer confirms. Must be resolved in meatspace.
// e. Failure to resolve in meatspace? Contact admin to arbitrate and force
//    a resolution.
//
// WARNING: never send ETH to this contract directly. Include value for
//          payment within the transaction when calling the buy() function.
//
// WARNING: if arranging sale by ERC20 token, take special care of the token
//          SCA passed to submit() - escrobot will confirm that a smart
//          contract exists there, but takes no additional steps to confirm
//          whatever is at that address is an ERC20 token contract.
//
// WARNING: never transfer() tokens to this smart contract. Use the token
//          contract's approve() function, and then call the buy() function
//          on this contract, which will transferFrom() the token contract.
//
// ==========================================================================

contract escrobot is Admin {

  event Submitted( bytes32 indexed orderId, address indexed seller );
  event Canceled( bytes32 indexed orderId, address indexed seller );
  event Paid( bytes32 indexed orderId, address indexed buyer );
  event TimedOut( bytes32 indexed orderId, address indexed buyer );
  event Shipped( bytes32 indexed orderId,
                 string shipRef,
                 address indexed seller );
  event Completed( bytes32 indexed orderId, address indexed buyer );
  event Noted( bytes32 indexed orderId, string note, address indexed noter );
  event WithdrawalQueued(
    bytes32 indexed orderId,
    address indexed account,
    uint8 indexed reason,
    uint256 amount
  );
  event Withdrawal( address indexed account, uint256 amount );

  enum State { SUBMITTED, CANCELED, PAID, TIMEDOUT, SHIPPED, COMPLETED }

  struct Order {
    address payable seller;
    address payable buyer;
    string description;
    uint256 price;        // in units of:
    address token;        // ERC20 token sca, or address(0x0) for ETH/wei
    uint256 bond;         // same units as token
    uint256 timeoutBlocks;
    uint256 takenBlock;
    string shipRef;
    State status;
  }

  mapping( bytes32 => Order ) public orders;
  mapping( address => uint256 ) public pendingWithdrawals;

  uint8 private constant WITHDRAWAL_OVERPAY_REFUND = 1;
  uint8 private constant WITHDRAWAL_TIMEOUT_REFUND = 2;
  uint8 private constant WITHDRAWAL_CONFIRM_SELLER = 3;
  uint8 private constant WITHDRAWAL_CONFIRM_BUYER = 4;
  uint8 private constant WITHDRAWAL_FORCE_RESOLVE_SELLER = 5;
  uint8 private constant WITHDRAWAL_FORCE_RESOLVE_BUYER = 6;

  // enable direct access to storage rather than going through the event log
  mapping( uint => bytes32 ) public indices;
  uint256 public indexcounter; // next index for indices

  uint256 public hashcounter; // help maintain hash uniqueness

  // SUPPORTING/INTERNAL ----------------------------------------------------

  modifier isSeller( bytes32 _orderId ) {
    require( msg.sender == orders[_orderId].seller, "only seller" );
    _;
  }
  modifier isBuyer( bytes32 _orderId ) {
    require( msg.sender == orders[_orderId].buyer, "only buyer" );
    _;
  }

  function isContract( address _addr ) private view returns (bool) {
    uint32 size;
    assembly {
      size := extcodesize(_addr)
    }
    return (size > 0);
  }

  function status( bytes32 _orderId ) public view returns (State) {
    return orders[_orderId].status;
  }

  function _queueWithdrawal(
    bytes32 _orderId,
    address _to,
    uint8 _reason,
    uint256 _amount
  ) private {
    if (_amount == 0) return;
    pendingWithdrawals[_to] += _amount;
    emit WithdrawalQueued( _orderId, _to, _reason, _amount );
  }

  function withdraw() external {
    uint256 amount = pendingWithdrawals[msg.sender];
    require( amount > 0, "nothing to withdraw" );

    pendingWithdrawals[msg.sender] = 0;

    (bool success, ) = payable(msg.sender).call{ value: amount }("");
    require( success, "withdraw failed" );
    emit Withdrawal( msg.sender, amount );
  }

  // enable clients to enumerate Orders from storage, array-like usage
  function indexToOrder( uint ix ) external view returns (Order memory) {
    return orders[ indices[ix] ];
  }

  // CORE --------------------------------------------------------------------

  // 1. Seller creates the Order

  function submit( string memory _desc,
                   uint256 _price,
                   address _token,
                   uint256 _bond,
                   uint256 _timeoutBlocks ) external {

    require( bytes(_desc).length > 1, "needs description" );
    require( _price > 0, "needs price" );
    require( _token == address(0x0) || isContract(_token), "bad token" );
    require( _price + _bond >= _price, "safemath" );
    require( _timeoutBlocks > 0, "needs timeout" );

    bytes32 orderId = keccak256( abi.encodePacked(
      hashcounter++,
      _desc,
      _price,
      _token,
      _bond,
      _timeoutBlocks,
      block.timestamp) );

    orders[orderId].seller = payable(msg.sender);
    orders[orderId].description = _desc;
    orders[orderId].price = _price;
    orders[orderId].token = _token;
    orders[orderId].bond = _bond;
    orders[orderId].timeoutBlocks = _timeoutBlocks;
    orders[orderId].status = State.SUBMITTED;

    indices[indexcounter++] = orderId;

    emit Submitted( orderId, msg.sender );
  }

  // 1a. Seller may cancel the order before Buyer has paid

  function cancel( bytes32 _orderId ) external isSeller(_orderId) {

    require( orders[_orderId].status == State.SUBMITTED, "not SUBMITTED" );
    orders[_orderId].status = State.CANCELED; // guard
    emit Canceled( _orderId, msg.sender );
  }

  // 2. Buyer pays sellers demand plus the bond/deposit.
  //    If paying by ERC20, the buyer must already have called approve()

  function buy( bytes32 _orderId ) payable external {

    require( orders[_orderId].status == State.SUBMITTED, "not SUBMITTED" );

    orders[_orderId].status = State.PAID; // guard

    uint256 needed = orders[_orderId].price + orders[_orderId].bond;
    if (orders[_orderId].token == address(0x0)) {
      require( msg.value >= needed, "insufficient ETH" );
      if (msg.value > needed)
        _queueWithdrawal(
          _orderId,
          msg.sender,
          WITHDRAWAL_OVERPAY_REFUND,
          (msg.value - needed)
        );
    }
    else {
      require(msg.value == 0, "no ETH with token buy"); // could get trapped
      require( ERC20(orders[_orderId].token).transferFrom(msg.sender,
        address(this), needed), "transferFrom()" );
    }

    orders[_orderId].buyer = payable(msg.sender);
    orders[_orderId].takenBlock = block.number;
    emit Paid( _orderId, msg.sender );
  }

  // 2b. If the seller fails to ship within the promised number of blocks, the
  // buyer may reclaim his payment and bond

  function timeout( bytes32 _orderId ) external isBuyer(_orderId) {

    require( orders[_orderId].status == State.PAID, "not PAID" );
    require( block.number > orders[_orderId].takenBlock +
                            orders[_orderId].timeoutBlocks, "too early" );
    require( bytes(orders[_orderId].shipRef).length == 0, "shipped already" );

    orders[_orderId].status = State.TIMEDOUT; // guard

    uint256 total = orders[_orderId].price + orders[_orderId].bond;
    if ( orders[_orderId].token == address(0x0) ) {
      _queueWithdrawal(
        _orderId,
        orders[_orderId].buyer,
        WITHDRAWAL_TIMEOUT_REFUND,
        total
      );
    }
    else {
      require(
        ERC20(orders[_orderId].token).transfer( orders[_orderId].buyer, total ),
        "token transfer failed"
      );
    }

    orders[_orderId].buyer = payable(0x0);
    orders[_orderId].takenBlock = 0;
    emit TimedOut( _orderId, msg.sender );
  }

  // 3. Seller provides the shipping/tracking reference information.

  function ship( bytes32 _orderId, string memory _shipRef )
  external isSeller(_orderId) {

    require(   orders[_orderId].status == State.PAID
            || orders[_orderId].status == State.SHIPPED, "ship state invalid" );

    require( bytes(_shipRef).length > 1, "Ref invalid" );

    orders[_orderId].status = State.SHIPPED; // guard
    orders[_orderId].shipRef = _shipRef;
    emit Shipped( _orderId, _shipRef, msg.sender );
  }

  // 4. Buyer confirms order has arrived and completes deal.

  function confirm( bytes32 _orderId ) external isBuyer(_orderId) {

    require( orders[_orderId].status == State.SHIPPED, "not SHIPPED" );

    orders[_orderId].status = State.COMPLETED; // guard against reentrance

    // 5. escrobot pays Seller and refunds Buyer

    if ( orders[_orderId].token == address(0x0) ) {
      _queueWithdrawal(
        _orderId,
        orders[_orderId].seller,
        WITHDRAWAL_CONFIRM_SELLER,
        orders[_orderId].price
      );
      _queueWithdrawal(
        _orderId,
        orders[_orderId].buyer,
        WITHDRAWAL_CONFIRM_BUYER,
        orders[_orderId].bond
      );
    }
    else {
      require(
        ERC20( orders[_orderId].token )
          .transfer( orders[_orderId].buyer, orders[_orderId].bond ),
        "return bond tokens to buyer failed"
      );

      require(
        ERC20( orders[_orderId].token )
          .transfer( orders[_orderId].seller, orders[_orderId].price ),
        "payment in tokens to seller failed"
      );
    }

    emit Completed( _orderId, msg.sender );
  }

  // Buyer, seller, admin can attach unencrypted notes to resolve disputes etc

  function note( bytes32 _orderId, string memory _noteplaintxt ) public {

    require(    msg.sender == orders[_orderId].buyer
             || msg.sender == orders[_orderId].seller
             || msg.sender == admin, "parties only" );

    emit Noted( _orderId, _noteplaintxt, msg.sender );
  }

  // ADMIN --------------------------------------------------------------------

  constructor() { }

  // ARBITRATION --------------------------------------------------------------

  // admin must handle rare/edge cases when something goes wrong IRL, e.g.:
  //   - seller lies about shipping
  //   - buyer lies and claims the shipment failed to arrive
  //   - shipment was lost/stolen in transit and shipper refuses to reship
  //
  // one party has to contact admin and prompt arbitration, admin has to do
  // some offchain verification and then admin force-resolves the order
  //
  // this requires an agent and/or human to monitor a channel for arbitration
  // requests and act promptly and in good faith

  function forceResolve(
    bytes32 _orderId,
    string calldata _reason,
    uint256 amtToSeller,
    uint256 amtToBuyer ) external isAdmin {

    require( orders[_orderId].status == State.SHIPPED,
             "must be SHIPPED to arbitrate" );

    require( amtToSeller + amtToBuyer ==
             orders[_orderId].price + orders[_orderId].bond,
             "payout exceeds order" );

    note( _orderId, _reason );

    if ( orders[_orderId].token == address(0x0) ) {
      _queueWithdrawal(
        _orderId,
        orders[_orderId].seller,
        WITHDRAWAL_FORCE_RESOLVE_SELLER,
        amtToSeller
      );
      _queueWithdrawal(
        _orderId,
        orders[_orderId].buyer,
        WITHDRAWAL_FORCE_RESOLVE_BUYER,
        amtToBuyer
      );
    }
    else {
      require(
        ERC20( orders[_orderId].token ).transfer(
          orders[_orderId].buyer, amtToBuyer ),
        "resolution payment of tokens to buyer failed"
      );

      require(
        ERC20( orders[_orderId].token ).transfer(
          orders[_orderId].seller, amtToSeller ),
        "resolution payment of tokens to seller failed"
      );
    }

    orders[_orderId].status = State.COMPLETED;
    emit Completed( _orderId, msg.sender );
  }
}
