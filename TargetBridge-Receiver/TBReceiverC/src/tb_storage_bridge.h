#ifndef TB_STORAGE_BRIDGE_H
#define TB_STORAGE_BRIDGE_H

/* Caller owns the UTF-8 JSON string and must free it. Returns a schema 1
 * snapshot of mounted removable/ejectable local volumes, or NULL on failure. */
char *tb_storage_copy_removable_volumes_json(void);

#endif
