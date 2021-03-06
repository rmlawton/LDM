/* 
 * Grammar for LDM configuration-file.
 */

%{
/*
 *   See file ../COPYRIGHT for copying and redistribution conditions.
 */

#include "config.h"

#include "acl.h"
#include "atofeedt.h"
#include "error.h"
#include "globals.h"
#include "remote.h"
#include "ldm.h"
#include "ldmprint.h"
#include "RegularExpressions.h"
#include "ulog.h"
#include "log.h"
#include "wordexp.h"

#include <limits.h>
#include <regex.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <errno.h>

#if YYDEBUG
extern int yydebug;
#endif

static int      line = 0;
static unsigned ldmPort = LDM_PORT;
static int      execute = 1;

static int              scannerPush(const char* const path);
static int              scannerPop(void);

static void
yyerror(const char *msg)
{
    log_add("Error in LDM configuration-file: %s", msg);
}

#if __STDC__
extern int yyparse(void);
#endif


static int
decodeFeedtype(
    feedtypet*  ftp,
    const char* string)
{
    feedtypet   ft;
    int         error;
    int         status = strfeedtypet(string, &ft);

    if (status == FEEDTYPE_OK) {
#if YYDEBUG
        if(yydebug)
            udebug("feedtype: %#x", ft);
#endif
        *ftp = ft;
        error = 0;
    }
    else {
        log_start("Invalid feedtype expression \"%s\": %s", string,
            strfeederr(status));

        error = 1;
    }

    return error;
}


static int
decodeRegEx(
    regex_t** const     regexpp,
    const char*         string)
{
    int         error = 1;              /* failure */

    if (strlen(string) == 0) {
        LOG_START0("Empty regular-expression");
        log_log(LOG_ERR);
    }
    else {
        char* const     clone = strdup(string);

        if (NULL == clone) {
            log_start("Couldn't clone regular-expression \"%s\": %s", string,
                    strerror(errno));
        }
        else {
            regex_t*    regexp = (regex_t*)malloc(sizeof(regex_t));

            if (NULL == regexp) {
                log_start("Couldn't allocate %lu bytes for \"regex_t\"",
                    (unsigned long)sizeof(regex_t));
            }
            else {
                if (re_vetSpec(clone)) {
                    /*
                     * Pathological regular expression.
                     */
                    log_start("Adjusted pathological regular expression \"%s\"",
                        string);
                    log_log(LOG_WARNING);
                }

                error = regcomp(regexp, clone,
                        REG_EXTENDED|REG_ICASE|REG_NOSUB);

                if (!error) {
                    *regexpp = regexp;
                }
                else {
                    char        buf[132];

                    (void)regerror(error, regexp, buf, sizeof(buf));
                    log_start("Couldn't compile regular-expression \"%s\": %s",
                            clone, buf);
                }

                if (error)
                    free(regexp);
            }                           /* "regexp" allocated */

            free(clone);
        }                               /* "clone" allocated */
    }                                   /* non-empty regular-expression */

    return error;
}


static int
decodeHostSet(
    host_set** const    hspp,
    const char*         string)
{
    regex_t*    regexp;
    int         error = decodeRegEx(&regexp, string);

    if (!error) {
        char* dup = strdup(string);

        if (NULL == dup) {
            log_start("Couldn't clone string \"%s\": %s", string,
                strerror(errno));
        }
        else {
            host_set*   hsp = new_host_set(HS_REGEXP, dup, regexp);

            if (NULL == hsp) {
                log_start("Couldn't create host-set for \"%s\": %s", dup,
                        strerror(errno));

                error = 1;
            }
            else {
#if YYDEBUG
                if(yydebug)
                    udebug("hostset: \"%s\"", dup);
#endif
                *hspp = hsp;
                error = 0;
            }

            if (error)
                free(dup);
        }                               /* "dup" set */

        if (error)
            regfree(regexp);

        free(regexp);
    }                           /* "regexp" set */

    return error;
}


static int
decodeSelection(
    feedtypet* const    ftp,
    regex_t** const     regexpp,
    const char* const   ftString,
    const char* const   regexString)
{
    feedtypet   ft;
    int         error;

    error = decodeFeedtype(&ft, ftString);

    if (!error) {
        error = decodeRegEx(regexpp, regexString);

        if (!error) {
#if YYDEBUG
            if(yydebug)
                udebug("prodIdPat: \"%s\"", regexString);
#endif
            *ftp = ft;
        }
    }                           /* feedtype decoded */

    return error;
}


static void
warnIfPathological(
    const char*  const  re)
{
    if (re_isPathological(re)) {
        /*
         * Pathological regular expression.
         */
        log_start("Pathological regular expression \"%s\"", re);
        log_log(LOG_WARNING);
    }
}


/*
 * Arguments:
 *      feedtypeSpec    String specification of feedtype.  May not be NULL.
 *                      Caller may free upon return.
 *      hostPattern     ERE of allowed hosts.  May not be NULL.  Caller may
 *                      free upon return.
 *      okPattern       ERE that product-identifiers must match in order for
 *                      the associated data-products to be transferred.  Caller
 *                      may free upon return.
 *      notPattern      ERE that product-identifiers must NOT match in order for
 *                      the associated data-products to be transferred.  May
 *                      be null to indicate that such matching should be
 *                      disabled.  Caller may free upon return.
 * Returns:
 *      0               Success.
 *      else            Failure.  "log_start()" called.
 */
static int
decodeAllowEntry(
    const char* const   feedtypeSpec,
    const char* const   hostPattern,
    const char* const   okPattern,
    const char* const   notPattern)
{
    feedtypet   ft;
    int         errCode = decodeFeedtype(&ft, feedtypeSpec);

    if (!errCode) {
        host_set*       hsp;

        errCode = decodeHostSet(&hsp, hostPattern);

        if (!errCode) {
            ErrorObj*   errObj;

            warnIfPathological(okPattern);

            if (notPattern)
                warnIfPathological(notPattern);

            errObj = acl_addAllow(ft, hsp, okPattern, notPattern);

            if (errObj) {
                log_start("Couldn't add ALLOW entry: feedSet=%s, hostPat=%s, "
                        "okPat=\"%s\", notPat=\"%s\"",
                        feedtypeSpec, hostPattern, okPattern, notPattern);
                free_host_set(hsp);
                errCode = -1;
            }
        }                               /* "hsp" allocated */
    }                                   /* "ft" set */

    return errCode;
}


static int
decodeRequestEntry(
    const char* const   feedtypeSpec,
    const char* const   prodPattern,
    char* const         hostSpec)
{
    feedtypet   feedtype;
    regex_t*    regexp;
    int         errCode =
            decodeSelection(&feedtype, &regexp, feedtypeSpec, prodPattern);

    if (!errCode) {
        const char*    hostId = strtok(hostSpec, ":");
    
        if (NULL == hostId) {
            log_start("Invalid hostname specification \"%s\"", hostSpec);
    
            errCode = EINVAL;
        }
        else {
            unsigned    localPort;
            const char* portSpec = strtok(NULL, ":");
        
            if (NULL == portSpec) {
                localPort = ldmPort;
            }
            else {
                char*   suffix = "";
                long    port;
        
                errno = 0;
                port = strtol(portSpec, &suffix, 0);
        
                if (0 == errno && 0 == *suffix && 0 < port && 0xffff >= port) {
                    localPort = (unsigned)port;
                }
                else {
                    log_start("Invalid port specification \"%s\"", portSpec);
        
                    errCode = EINVAL;
                }
            } /* have port specification */
        
            if (0 == errCode) {
                if (errCode = acl_addRequest(feedtype, prodPattern, hostId,
                        localPort)) {
                }
            } /* "localPort" set */
        } /* valid hostname */
    
        regfree(regexp);
        free(regexp);
    } /* "regexp" allocated */
    
    if (errCode)
        LOG_ADD3("Couldn't process REQUEST: host=%s, feedSet=%s, "
                "prodPat=\"%s\"", hostSpec, feedtypeSpec, prodPattern);

    return errCode;
}


#if YYDEBUG
#define printf udebug
#endif

%}

%union  {
                char    string[2000];
        }


%token ALLOW_K
%token ACCEPT_K
%token REQUEST_K
%token EXEC_K
%token INCLUDE_K

%token <string> STRING

%start table

%%
table:          /* empty */
                | table entry
                ;

entry:            allow_entry
                | accept_entry
                | request_entry
                | exec_entry
                | include_stmt
                ;

allow_entry:    ALLOW_K STRING STRING
                {
                    int errCode = decodeAllowEntry($2, $3, ".*", NULL);

                    if (errCode)
                        return errCode;
                }
                | ALLOW_K STRING STRING STRING
                {
                    int errCode = decodeAllowEntry($2, $3, $4, NULL);

                    if (errCode)
                        return errCode;
                }
                | ALLOW_K STRING STRING STRING STRING
                {
                    int errCode = decodeAllowEntry($2, $3, $4, $5);

                    if (errCode)
                        return errCode;
                }
                ;

accept_entry:   ACCEPT_K STRING STRING STRING
                {
                    feedtypet   ft;
                    regex_t*    regexp;
                    int         error = decodeSelection(&ft, &regexp, $2, $3);

                    if (!error) {
                        host_set*       hsp;

                        error = decodeHostSet(&hsp, $4);

                        if (!error) {
                            char*       patp = strdup($3);

                            if (NULL == patp) {
                                log_start("Couldn't clone string \"%s\": %s",
                                    $3, strerror(errno));

                                error = 1;
                            }
                            else {
                                error =
                                    accept_acl_add(ft, patp, regexp, hsp, 1);

                                if (!error) {
                                    patp = NULL;    /* abandon */
                                    hsp = NULL;     /* abandon */
                                    regexp = NULL;  /* abandon */
                                }
                                else {
                                    free(patp);
                                }
                            }           /* "patp" allocated */

                            if (error)
                                free_host_set(hsp);
                        }               /* "*hsp" allocated */

                        if (error && regexp) {
                            regfree(regexp);
                            free(regexp);
                        }
                    }                   /* "regexp" allocated */

                    if (error) {
                        LOG_ADD3("Couldn't process ACCEPT: feedSet=\"%s\""
                                "prodPat=\"%s\", hostPat=\"%s\"", $2, $3, $4);
                        return error;
                    }
                }
                ;

request_entry:  REQUEST_K STRING STRING STRING
                {
                    int errCode = decodeRequestEntry($2, $3, $4);

                    if (errCode)
                        return errCode;
                }
                | REQUEST_K STRING STRING STRING STRING
                {
                    int errCode = decodeRequestEntry($2, $3, $4);

                    if (errCode)
                        return errCode;
                }
                ;

exec_entry:     EXEC_K STRING
                {
                    wordexp_t   words;
                    int         error;

                    (void)memset(&words, 0, sizeof(words));

                    error = wordexp($2, &words, 0);

                    if (error) {
                        log_start("Couldn't decode command \"%s\": %s",
                            strerror(errno));
                    }
                    else {
#if YYDEBUG
                        if(yydebug)
                            udebug("command: \"%s\"", $2);
#endif
                        if (execute)
                            error = exec_add(&words);
                        
                        if (!execute || error)
                            wordfree(&words);
                    }                   /* "words" set */

                    if (error) {
                        LOG_ADD1("Couldn't process EXEC: cmd=\"%s\"", $2);
                        return error;
                    }
                }
                ;

include_stmt:   INCLUDE_K STRING
                {
                    if (scannerPush($2))
                        return -1;
                }

%%

#include "scanner.c"

/*
 * Returns:
 *       0      More input
 *      !0      No more input
 */
int
yywrap(void)
{
    return scannerPop();
}

/*
 * Arguments:
 *      conf_path       Pathname of configuration-file.
 *      doSomething     Whether or not to actually do something or just
 *                      parse the configuration-file.
 *      defaultPort     The default LDM port.
 * Returns:
 *      0               Success.
 *      !0              Failure.  "log_start()" called.
 */
int
read_conf(
    const char* const   conf_path,
    int                 doSomething,
    unsigned            defaultPort)
{
    int                 status = -1;    /* failure */

    if (scannerPush(conf_path)) {
        log_add("Couldn't open LDM configuration-file");
    }
    else {
        /* yydebug = 1; */
        ldmPort = defaultPort;
        execute = doSomething;
        status = yyparse();

        if (status != 0) {
            log_add("Error reading LDM configuration-file \"%s\"", conf_path);
        }
        else {
            if (doSomething) {
                status = invert_request_acl(defaultPort);

                if (status != 0)
                    log_serror("Problem requesting data");
            }
        }
    }

    return status;
}
