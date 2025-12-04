import re
import sys

def patch_file(filepath, description, patch_func):
    try:
        with open(filepath, 'r') as f:
            content = f.read()
        
        new_content = patch_func(content)
        
        if new_content != content:
            with open(filepath, 'w') as f:
                f.write(new_content)
            print(f"  [✓] {filepath} patched ({description})")
        else:
            print(f"  [!] {filepath} not changed (pattern not found or already patched?)")
            
    except Exception as e:
        print(f"  [✗] Failed to patch {filepath}: {e}")
        sys.exit(1)

# ==========================================
# 1. Patch fs/open.c (Core Logic & vfs_open)
# ==========================================
def patch_open_c(content):
    # Add necessary includes
    includes = (
        "#include <linux/proc_fs.h>\n"
        "#include <linux/uaccess.h>\n"
        "#include <linux/slab.h>\n"
        "#include <linux/namei.h>\n"
        "#include <linux/dcache.h>\n"
        "#include <linux/mount.h>\n"
    )
    
    if "Hymo VFS Hook" in content:
        return content

    content = re.sub(r'(#include <linux/syscalls.h>)', r'\1\n' + includes, content)

    # Core Hook Logic
    hook_code = (
        "\n/* Hymo VFS Hook - Dynamic Path Redirection */\n"
        "#define HYMO_MAX_MODULES 256\n"
        "#define HYMO_MODULE_NAME_LEN 64\n"
        "\n"
        "struct hymo_module {\n"
        "    char name[HYMO_MODULE_NAME_LEN];\n"
        "    bool enabled;\n"
        "};\n"
        "\n"
        "static struct {\n"
        "    struct hymo_module modules[HYMO_MAX_MODULES];\n"
        "    int count;\n"
        "    spinlock_t lock;\n"
        "    atomic_t version;\n"
        "} hymo_state = {\n"
        "    .count = 0,\n"
        "    .lock = __SPIN_LOCK_UNLOCKED(hymo_state.lock),\n"
        "    .version = ATOMIC_INIT(0),\n"
        "};\n"
        "\n"
        "/* Control interface: echo \"add module_name\" > /proc/hymo_ctl */\n"
        "static ssize_t hymo_ctl_write(struct file *file, const char __user *buffer,\n"
        "                  size_t count, loff_t *pos)\n"
        "{\n"
        "    char cmd[256];\n"
        "    char op[16], name[HYMO_MODULE_NAME_LEN];\n"
        "    int i;\n"
        "    unsigned long flags;\n"
        "\n"
        "    if (count >= sizeof(cmd)) return -EINVAL;\n"
        "    if (copy_from_user(cmd, buffer, count)) return -EFAULT;\n"
        "    cmd[count] = '\\0';\n"
        "    if (sscanf(cmd, \"%15s %63s\", op, name) != 2) return -EINVAL;\n"
        "\n"
        "    spin_lock_irqsave(&hymo_state.lock, flags);\n"
        "    if (strcmp(op, \"add\") == 0) {\n"
        "        for (i = 0; i < hymo_state.count; i++) {\n"
        "            if (strcmp(hymo_state.modules[i].name, name) == 0) {\n"
        "                hymo_state.modules[i].enabled = true;\n"
        "                goto updated;\n"
        "            }\n"
        "        }\n"
        "        if (hymo_state.count < HYMO_MAX_MODULES) {\n"
        "            strncpy(hymo_state.modules[hymo_state.count].name, name, HYMO_MODULE_NAME_LEN - 1);\n"
        "            hymo_state.modules[hymo_state.count].enabled = true;\n"
        "            hymo_state.count++;\n"
        "        }\n"
        "    } else if (strcmp(op, \"del\") == 0) {\n"
        "        for (i = 0; i < hymo_state.count; i++) {\n"
        "            if (strcmp(hymo_state.modules[i].name, name) == 0) {\n"
        "                hymo_state.modules[i].enabled = false;\n"
        "                goto updated;\n"
        "            }\n"
        "        }\n"
        "    } else if (strcmp(op, \"clear\") == 0) {\n"
        "        hymo_state.count = 0;\n"
        "    }\n"
        "updated:\n"
        "    atomic_inc(&hymo_state.version);\n"
        "    spin_unlock_irqrestore(&hymo_state.lock, flags);\n"
        "    return count;\n"
        "}\n"
        "\n"
        "static const struct proc_ops hymo_ctl_ops = {\n"
        "    .proc_write = hymo_ctl_write,\n"
        "};\n"
        "\n"
        "static int __init hymo_vfs_init(void)\n"
        "{\n"
        "    proc_create(\"hymo_ctl\", 0660, NULL, &hymo_ctl_ops);\n"
        "    return 0;\n"
        "}\n"
        "fs_initcall(hymo_vfs_init);\n"
        "\n"
        "bool hymo_vfs_redirect(const struct path *path, struct path *new_path)\n"
        "{\n"
        "    char *pathname, *buf, *redirect_buf;\n"
        "    bool redirected = false;\n"
        "    int i, ret;\n"
        "    unsigned long flags;\n"
        "\n"
        "    if (atomic_read(&hymo_state.version) == 0) return false;\n"
        "    if (!path || !path->dentry || !path->mnt) return false;\n"
        "\n"
        "    buf = kmalloc(PATH_MAX, GFP_ATOMIC);\n"
        "    if (!buf) return false;\n"
        "\n"
        "    pathname = d_path(path, buf, PATH_MAX);\n"
        "    if (IS_ERR(pathname)) { kfree(buf); return false; }\n"
        "\n"
        "    if (strncmp(pathname, \"/system/\", 8) != 0 &&\n"
        "        strncmp(pathname, \"/vendor/\", 8) != 0 &&\n"
        "        strncmp(pathname, \"/product/\", 9) != 0) {\n"
        "        kfree(buf); return false;\n"
        "    }\n"
        "\n"
        "    redirect_buf = kmalloc(PATH_MAX, GFP_ATOMIC);\n"
        "    if (!redirect_buf) { kfree(buf); return false; }\n"
        "\n"
        "    spin_lock_irqsave(&hymo_state.lock, flags);\n"
        "    for (i = 0; i < hymo_state.count; i++) {\n"
        "        if (!hymo_state.modules[i].enabled) continue;\n"
        "        snprintf(redirect_buf, PATH_MAX, \"/data/adb/hymo/modules/%s%s\",\n"
        "             hymo_state.modules[i].name, pathname);\n"
        "        spin_unlock_irqrestore(&hymo_state.lock, flags);\n"
        "\n"
        "        ret = kern_path(redirect_buf, LOOKUP_FOLLOW, new_path);\n"
        "        if (ret == 0) {\n"
        "            redirected = true;\n"
        "            goto found;\n"
        "        }\n"
        "        spin_lock_irqsave(&hymo_state.lock, flags);\n"
        "    }\n"
        "    spin_unlock_irqrestore(&hymo_state.lock, flags);\n"
        "found:\n"
        "    kfree(buf);\n"
        "    kfree(redirect_buf);\n"
        "    return redirected;\n"
        "}\n"
        "EXPORT_SYMBOL(hymo_vfs_redirect);\n"
        "\n"
        "static int hymo_vfs_open(const struct path *path, struct file *file)\n"
        "{\n"
        "    struct path redirect_path;\n"
        "    const struct path *final_path = path;\n"
        "    int ret;\n"
        "    if (hymo_vfs_redirect(path, &redirect_path))\n"
        "        final_path = &redirect_path;\n"
        "    file->f_path = *final_path;\n"
        "    ret = do_dentry_open(file, d_backing_inode(final_path->dentry), NULL);\n"
        "    if (final_path == &redirect_path) path_put(&redirect_path);\n"
        "    return ret;\n"
        "}\n"
    )

    # Inject hook code before vfs_open
    # Match: /** ... vfs_open ... */ int vfs_open(...) { ... }
    pattern = r'(/\*\*\s+\*\s+vfs_open.*?\*/\s+)(int\s+vfs_open\([^)]+\)\s+\{[^}]+\})'
    
    # Replace vfs_open body with wrapper call
    def replace_vfs_open(match):
        return match.group(1) + hook_code + "\nint vfs_open(const struct path *path, struct file *file)\n{\n    return hymo_vfs_open(path, file);\n}\n"

    return re.sub(pattern, replace_vfs_open, content, flags=re.DOTALL)

# ==========================================
# 2. Patch fs/stat.c (vfs_getattr)
# ==========================================
def patch_stat_c(content):
    decl = "\nextern bool hymo_vfs_redirect(const struct path *path, struct path *new_path);\n"
    if "hymo_vfs_redirect" not in content:
        content = re.sub(r'(#include "internal.h")', r'\1' + decl, content)

    new_vfs_getattr = (
        "int vfs_getattr(const struct path *path, struct kstat *stat,\n"
        "                u32 request_mask, unsigned int query_flags)\n"
        "{\n"
        "    struct path redirect_path;\n"
        "    const struct path *final_path = path;\n"
        "    int retval;\n"
        "\n"
        "    if (WARN_ON_ONCE(query_flags & AT_GETATTR_NOSEC))\n"
        "        return -EPERM;\n"
        "\n"
        "    if (hymo_vfs_redirect(path, &redirect_path))\n"
        "        final_path = &redirect_path;\n"
        "\n"
        "    retval = security_inode_getattr(final_path);\n"
        "    if (retval)\n"
        "        goto out;\n"
        "    retval = vfs_getattr_nosec(final_path, stat, request_mask, query_flags);\n"
        "out:\n"
        "    if (final_path == &redirect_path)\n"
        "        path_put(&redirect_path);\n"
        "    return retval;\n"
        "}\n"
        "EXPORT_SYMBOL_NS(vfs_getattr, ANDROID_GKI_VFS_EXPORT_ONLY);\n"
    )
    
    pattern = r'int\s+vfs_getattr\(const struct path \*path[^{]+\{[^}]*security_inode_getattr[^}]+return vfs_getattr_nosec[^}]+\}\s+EXPORT_SYMBOL[^;]+;'
    return re.sub(pattern, new_vfs_getattr, content, flags=re.DOTALL)

# ==========================================
# 3. Patch fs/namei.c (readlinkat -> vfs_readlink)
# ==========================================
def patch_namei_c(content):
    decl = "\nextern bool hymo_vfs_redirect(const struct path *path, struct path *new_path);\n"
    if "hymo_vfs_redirect" not in content:
        content = re.sub(r'(#include "internal.h")', r'\1' + decl, content)

    # Helper function to handle redirection for readlink
    helper_func = (
        "\nstatic int hymo_vfs_readlink(struct path *path, char __user *buf, int buflen)\n"
        "{\n"
        "    struct path redirect_path;\n"
        "    int ret;\n"
        "    if (hymo_vfs_redirect(path, &redirect_path)) {\n"
        "        ret = vfs_readlink(redirect_path.dentry, buf, buflen);\n"
        "        path_put(&redirect_path);\n"
        "        return ret;\n"
        "    }\n"
        "    return vfs_readlink(path->dentry, buf, buflen);\n"
        "}\n"
    )
    
    # Insert helper before do_readlinkat
    content = re.sub(r'(static int do_readlinkat)', helper_func + r'\1', content)

    # Replace vfs_readlink call inside do_readlinkat
    # Look for: error = vfs_readlink(path.dentry, buf, buflen);
    pattern = r'(error\s*=\s*)vfs_readlink\(path\.dentry,\s*buf,\s*buflen\);'
    content = re.sub(pattern, r'\1hymo_vfs_readlink(&path, buf, buflen);', content)
    
    return content

# ==========================================
# 4. Patch fs/xattr.c (path_getxattr/listxattr)
# ==========================================
def patch_xattr_c(content):
    decl = "\nextern bool hymo_vfs_redirect(const struct path *path, struct path *new_path);\n"
    if "hymo_vfs_redirect" not in content:
        content = re.sub(r'(#include "internal.h")', r'\1' + decl, content)

    # Helper for getxattr
    helper_get = (
        "\nstatic ssize_t hymo_path_getxattr(struct path *path, const char *name, void *value, size_t size)\n"
        "{\n"
        "    struct path redirect_path;\n"
        "    ssize_t ret;\n"
        "    if (hymo_vfs_redirect(path, &redirect_path)) {\n"
        "        ret = vfs_getxattr(mnt_idmap(redirect_path.mnt), redirect_path.dentry, name, value, size);\n"
        "        path_put(&redirect_path);\n"
        "        return ret;\n"
        "    }\n"
        "    return vfs_getxattr(mnt_idmap(path->mnt), path->dentry, name, value, size);\n"
        "}\n"
    )
    
    # Helper for listxattr
    helper_list = (
        "\nstatic ssize_t hymo_path_listxattr(struct path *path, char *list, size_t size)\n"
        "{\n"
        "    struct path redirect_path;\n"
        "    ssize_t ret;\n"
        "    if (hymo_vfs_redirect(path, &redirect_path)) {\n"
        "        ret = vfs_listxattr(redirect_path.dentry, list, size);\n"
        "        path_put(&redirect_path);\n"
        "        return ret;\n"
        "    }\n"
        "    return vfs_listxattr(path->dentry, list, size);\n"
        "}\n"
    )

    # Insert helpers
    content = re.sub(r'(static int path_getxattr)', helper_get + r'\1', content)
    content = re.sub(r'(static int path_listxattr)', helper_list + r'\1', content)

    # Patch path_getxattr
    # Match: error = vfs_getxattr(mnt_idmap(path.mnt), path.dentry, name, value, size);
    # Note: mnt_idmap might not be present in older kernels, but 6.6 has it.
    # We use a loose regex to match arguments.
    pattern_get = r'(error\s*=\s*)vfs_getxattr\([^,]+,\s*path\.dentry,\s*name,\s*value,\s*size\);'
    content = re.sub(pattern_get, r'\1hymo_path_getxattr(&path, name, value, size);', content)

    # Patch path_listxattr
    # Match: error = vfs_listxattr(path.dentry, list, size);
    pattern_list = r'(error\s*=\s*)vfs_listxattr\(path\.dentry,\s*list,\s*size\);'
    content = re.sub(pattern_list, r'\1hymo_path_listxattr(&path, list, size);', content)

    return content

# ==========================================
# Main Execution
# ==========================================
print(">>> Hymo VFS Patcher (Corrected Version) <<<")
patch_file('fs/open.c', 'vfs_open hook', patch_open_c)
patch_file('fs/stat.c', 'vfs_getattr hook', patch_stat_c)
patch_file('fs/namei.c', 'readlinkat hook', patch_namei_c)
patch_file('fs/xattr.c', 'xattr hooks', patch_xattr_c)
