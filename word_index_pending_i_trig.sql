/* create trigger on word_index_pending */
create trigger word_index_pending_i_trig
ON word_index_pending
FOR insert
AS
insert into hcl_solr_pending(Action,RecNum,RecType)
select Action,RecNum,RecType from inserted
