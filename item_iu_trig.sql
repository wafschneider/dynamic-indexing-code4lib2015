/*
   Copyright 2000-2002 epixtech, inc.  All rights reserved.
   Copyright 2003-2004 Dynix Corporation. All rights reserved.
   Copyright SirsiDynix 2008.  All rights reserved.
   HCL modified 5/1/2013 (was) to record bib number
     in hcl_solr_pending
 */
 CREATE TRIGGER item_iu_trig
 ON item
 FOR insert, update
 AS
 DECLARE @num_rows      int,
         @colSize       int,
         @item#         int
 SELECT @num_rows = @@rowcount
 IF update (bib#)
  /* foreign referential integrity, null NOT allowed */
  IF @num_rows !=
     (SELECT count(*) FROM bib, inserted
      WHERE bib.bib# = inserted.bib#
        and bib.tag = '000'
        and substring(bib.text,6,1) != 'd')
    BEGIN
      ROLLBACK transaction
      RAISERROR 20001 'bad or deleted bib# in item'
      RETURN
    END
 IF update (location)
  BEGIN
    /* foreign referential integrity, null NOT allowed */
    IF @num_rows !=
       (SELECT count(*) FROM location, inserted
        WHERE location.location = inserted.location)
      BEGIN
        ROLLBACK transaction
        RAISERROR 20001 'bad location in item'
        RETURN
      END
    /* insert into pms_item ON all new inserts or a change to item.location */
    insert pms_item (item#, action)
      SELECT item#, 2 FROM inserted
      WHERE delete_flag = 0
  END
 IF update (collection)
  BEGIN
    /* foreign referential integrity, null NOT allowed */
    IF @num_rows !=
       (SELECT count(*) FROM collection, inserted
        WHERE collection.collection = inserted.collection)
      BEGIN
        ROLLBACK transaction
        RAISERROR 20001 'bad collection in item'
        RETURN
      END
    /* DeCounts.exe now updates the counts.  This is needed for the first
       item so the collection cannot be deleted.  The 'IF EXISTS' is needed
       to prevent locking the table IF there is no update needed. */
    IF EXISTS (SELECT * FROM collection c, inserted i
               WHERE i.collection = c.collection and c.n_items = 0)
    update collection
      SET n_items = 1
      FROM inserted i, collection c
      WHERE i.collection = c.collection and c.n_items = 0

    /* HCL modification: insert row into hcl_solr_pending table for availability indexing */
    insert into hcl_solr_pending (RecNum,RecType,Action) select bib#,0,2 from inserted
  END
 IF update (itype)
  BEGIN
    /* foreign referential integrity, null NOT allowed */
    IF @num_rows != (SELECT count(*) FROM itype, inserted
        WHERE itype.itype = inserted.itype)
      BEGIN
        ROLLBACK transaction
        RAISERROR 20001 'bad itype in item'
        RETURN
      END
    /* DeCounts.exe now updates the counts.  This is needed for the first
       item so the itype cannot be deleted.  The 'IF EXISTS' is needed
       to prevent locking the table IF there is no update needed. */
    IF EXISTS (SELECT * FROM itype it, inserted i
               WHERE i.itype = it.itype and it.n_items = 0)
    update itype
      SET n_items = 1
      FROM inserted i, itype it
      WHERE i.itype = it.itype and it.n_items = 0
    /* HCL modification: insert row into hcl_solr_pending table for availability indexing */
    insert into hcl_solr_pending (RecNum,RecType,Action) select bib#,0,2 from inserted
  END
IF update (item_status)
  BEGIN
    /* foreign referential integrity, null NOT allowed */
    IF @num_rows != (SELECT count(*) FROM item_status, inserted
        WHERE item_status.item_status = inserted.item_status)
      BEGIN
        ROLLBACK transaction
        RAISERROR 20001 'bad item_status in item'
        RETURN
      END
    /* DeCounts.exe now updates the counts.  This is needed for the first
       item so the item_status cannot be deleted.  The 'IF EXISTS' is needed
       to prevent locking the table IF there is no update needed. */
    IF EXISTS (SELECT * FROM item_status it, inserted i
               WHERE i.item_status = it.item_status and it.n_items = 0)
    update item_status
      SET n_items = 1
      FROM inserted i,item_status it
      WHERE i.item_status = it.item_status and it.n_items = 0
    /* insert circ when changing item_status to 'o' */
    IF EXISTS (SELECT * FROM inserted WHERE item_status = 'o')
      insert circ (borrower#, item#, proxy_borrower#)
       SELECT borrower#, item#, proxy_borrower#
        FROM inserted
        WHERE item_status = 'o'
    /* delete pick_list_source when
       changing item_status FROM 'rb' to anything else
       reformulated query to join (JMC) */
    IF EXISTS (SELECT * FROM deleted WHERE item_status = 'rb')
      delete pick_list_source
      FROM pick_list_source p, deleted d WHERE p.item# = d.item#
    /* insert pick_list_source when
       changing item_status to 'rb' */
    IF EXISTS (SELECT * FROM inserted WHERE item_status = 'rb')
      insert pick_list_source (rbr_location, pick_location, item#)
        SELECT saved_location, location, item#
        FROM inserted
        WHERE item_status = 'rb'
    /* check IF the new item status is SET FORtracking */
    IF EXISTS (SELECT * FROM item_status it, inserted i
               WHERE i.available_date is null
                 and i.item_status = it.item_status and it.first_availability = 1)
       update item SET available_date = datediff (dd,'1 Jan 1970', getdate())
       FROM item, inserted
       WHERE inserted.available_date is null
         and item.item# = inserted.item#
    update item SET last_status_update_date =
      datediff (dd, '1 Jan 1970', getdate() )
    FROM item, inserted
    WHERE item.item# = inserted.item#
    /* HCL modification: insert row into hcl_solr_pending table for availability indexing */
    insert into hcl_solr_pending (RecNum,RecType,Action) select bib#,0,2 from inserted
  END
 IF update(delete_flag)
  BEGIN
    /* The next two IF statements ensure that no rows are deleted for
       items that are either checked out or part of a current request.
       If you modify these statements, be sure to also modify the code
       in DbThanatos.mod which performs these same checks programatically.
    */
    IF EXISTS(SELECT * FROM circ c, inserted i, deleted d
              WHERE c.item#=i.item#
                and i.delete_flag=1
                and d.delete_flag=0)
      BEGIN
        ROLLBACK transaction
        RAISERROR 20001 'Can''t delete item that is checked out.'
        RETURN
      END
    IF EXISTS(SELECT * FROM request r, inserted i, deleted d
              WHERE (r.item#=i.item# or r.fill_item#=i.item#)
                andi.delete_flag=1
                and d.delete_flag=0)
      BEGIN
        ROLLBACK transaction
        RAISERROR 20001 'Can''t delete item that has been requested.'
        RETURN
      END
    delete advanced_booking
      FROM advanced_booking, inserted
      WHERE inserted.delete_flag = 1
      and advanced_booking.booked_item# = inserted.item#
    delete circ_history
      FROM circ_history, inserted
      WHERE inserted.delete_flag = 1 and circ_history.item# = inserted.item#
    delete item_transit
      FROM item_transit, inserted
      WHERE inserted.delete_flag = 1 and item_transit.item# = inserted.item#
    delete reliance_exception
      FROM reliance_exception, inserted
      WHERE inserted.delete_flag = 1
      and reliance_exception.item# = inserted.item#
    delete new_item
      FROM new_item, inserted
     WHERE inserted.delete_flag = 1
       and new_item.item# = inserted.item#
      /* insert pms_item: deletes.  Here, we must update an existing row or insert
   a new row into pms_item with action=3.  We'll do both and one will
       succeed. */
    update pms_item SET action = 3
      FROM pms_item, inserted
      WHERE inserted.delete_flag = 1
      and    pms_item.item# = inserted.item#
    insert pms_item (item#, action) /* may get thrown out by ignore_dup_key--that's the idea! */
      SELECT item#, 3 FROM inserted
      WHERE delete_flag = 1
  END
 IF update(due_date) or update(due_time)
  BEGIN
    IF EXISTS(SELECT b.item# FROM burb b, inserted
              WHERE (b.block = 'od' or b.block = 'odr')
              and b.item# = inserted.item# and b.borrower# = inserted.borrower#)
      BEGIN
        ROLLBACK transaction
        RAISERROR 20001 'Can''t change due date IF over due block EXISTS, try renewing the item.'
        RETURN
      END
  END
 IF update(call) or update(call_reconst)
   BEGIN
     DECLARE @processed     varchar(255),
             @reconst       varchar(255),
             @reconstructed varchar(255)
     SELECT @colSize = col_length('item','call_reconstructed')
     SELECT @item# = min(item#) FROM inserted
     while (@item# IS NOT NULL)
     BEGIN
       SELECT @processed = call, @reconst = call_reconst FROM inserted
        WHERE item# = @item#
 exec reconstruct @processed, @reconst, @reconstructed output
       update item SET call_reconstructed = substring(@reconstructed,1,@colSize)
        WHERE item# = @item#
       SELECT @item# = min(item#) FROM inserted
        WHERE item# > @item#
    END
   END
 IF update(copy) or update(copy_reconst)
   BEGIN
     DECLARE @processeda     varchar(255),
             @reconsta       varchar(255),
             @reconstructeda varchar(255)
     SELECT @colSize = col_length('item','copy_reconstructed')
     SELECT @item# = min(item#) FROM inserted
     while (@item# IS NOT NULL)
     BEGIN
       SELECT @processeda = copy, @reconsta = copy_reconst FROM inserted
        WHERE item# = @item#
       exec reconstruct @processeda, @reconsta, @reconstructeda output
       update item SET copy_reconstructed = substring(@reconstructeda,1,@colSize)
        WHERE item# = @item#
       SELECT @item# = min(item#) FROM inserted
        WHERE item# > @item#
     END
   END
 /* HCL modification: insert row into hcl_solr_pending table for availability indexing */
 IF update(ibarcode)
   BEGIN
     insert into hcl_solr_pending (RecNum,RecType,Action) select bib#,0,2 from inserted
   END
 RETURN