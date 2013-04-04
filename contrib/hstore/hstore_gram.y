%{
#define YYPARSE_PARAM result  /* need this to pass a pointer (void *) to yyparse */

#include "postgres.h"

#include "fmgr.h"
#include "utils/builtins.h"
#include "hstore.h"

/*
 * Bison doesn't allocate anything that needs to live across parser calls,
 * so we can easily have it use palloc instead of malloc.  This prevents
 * memory leaks if we error out during parsing.  Note this only works with
 * bison >= 2.0.  However, in bison 1.875 the default is to use alloca()
 * if possible, so there's not really much problem anyhow, at least if
 * you're building with gcc.
 */
#define YYMALLOC palloc
#define YYFREE   pfree

/* Avoid exit() on fatal scanner errors (a bit ugly -- see yy_fatal_error) */
#undef fprintf
#define fprintf(file, fmt, msg)  fprintf_to_ereport(fmt, msg)

static void
fprintf_to_ereport(const char *fmt, const char *msg)
{
	ereport(ERROR, (errmsg_internal("%s", msg)));
}

/* struct string is shared between scan and gram */
typedef struct string {
	char 	*val;
	int  	len;
	int		total;
} string;
#include <hstore_gram.h>

/* flex 2.5.4 doesn't bother with a decl for this */
int hstore_yylex(YYSTYPE * yylval_param);
int hstore_yyparse(void *result);
void hstore_yyerror(const char *message);

static HStoreValue*
makeHStoreValueString(HStoreValue* v, string *s) {
	if (v == NULL)
		v = palloc(sizeof(*v));

	if (s == NULL)
	{
		v->type = hsvNullString;
		v->size = sizeof(HEntry);
	}
	else if (s->len > HENTRY_POSMASK)
	{
		elog(ERROR, "string is too long");
	}
	else
	{
		v->type = hsvString;
		v->string.val = s->val;
		v->string.len = s->len;
		v->size = sizeof(HEntry) + s->len;

	}

	return v;
}

static HStoreValue*
makeHStoreValueArray(List *list) {
	HStoreValue	*v = palloc(sizeof(*v));

	v->type = hsvArray;
	v->array.nelems = list_length(list);
	v->size = sizeof(uint32) /* header */ + sizeof(HEntry) /* parent's entry */ + sizeof(HEntry) - 1 /*alignment*/;

	if (v->array.nelems > 0) {
		ListCell	*cell;
		int			i = 0;

		v->array.elems = palloc(sizeof(HStoreValue) * v->array.nelems);

		foreach(cell, list) {
			HStoreValue	*s = (HStoreValue*)lfirst(cell);

			v->size += s->size; 

			v->array.elems[i++] = *s;

			if (v->size > HENTRY_POSMASK)
				elog(ERROR, "array is too long");
		}
	} else {
		v->array.elems = NULL;
	}

	return v;
}

static HStoreValue*
makeHStoreValuePairs(List *list) {
	HStoreValue	*v = palloc(sizeof(*v));

	v->type = hsvPairs;
	v->hstore.npairs = list_length(list);
	v->size = sizeof(uint32) /* header */ + sizeof(HEntry) /* parent's entry */ + sizeof(HEntry) - 1 /*alignment*/;

	if (v->hstore.npairs > 0) {
		ListCell	*cell;
		int			i = 0;

		v->hstore.pairs = palloc(sizeof(HStorePair) * v->hstore.npairs);

		foreach(cell, list) {
			HStorePair	*s = (HStorePair*)lfirst(cell);

			v->size += s->key.size + s->value.size; 
			v->hstore.pairs[i++] = *s;

			if (v->size > HENTRY_POSMASK)
				elog(ERROR, "hstore is too long");
		}

		ORDER_PAIRS(v->hstore.pairs, v->hstore.npairs, v->size -= ptr->key.size + ptr->value.size);
	} else {
		v->hstore.pairs = NULL;
	}

	return v;
}

static HStorePair*
makeHStoreStringPair(string *key, string *value) {
	HStorePair	*v = palloc(sizeof(*v));

	makeHStoreValueString(&v->key, key);
	makeHStoreValueString(&v->value, value);

	if (v->key.size + v->value.size > HENTRY_POSMASK)
		elog(ERROR, "pair is too long");

	return v;
}

static HStorePair*
makeHStorePair(string *key, HStoreValue *value) {
	HStorePair	*v = palloc(sizeof(*v));

	makeHStoreValueString(&v->key, key);
	v->value = *value;

	return v;
}

%}

/* BISON Declarations */
%pure-parser
%expect 0
%name-prefix="hstore_yy"
%error-verbose

%union {
	string 			str;
	List			*elems; 		/* list of HStoreValue */
	List			*pairs; 		/* list of HStorePair */
	HStoreValue		*hvalue;
	HStorePair		*pair;
}

%token	<str>			DELIMITER_P NULL_P STRING_P

%type	<hvalue>		hstore array result 
%type	<str>			key	nil

%type	<pair>			pair

%type	<elems>			array_list
%type 	<pairs>			pair_list

/* Grammar follows */
%%

result: 
	pair_list						{ *((HStoreValue**)result) = makeHStoreValuePairs($1); }
	/* | hstore						{ *((HStoreValue**)result) = $1; } XXX is it needed or wanted? */
	| array							{ *((HStoreValue**)result) = $1; }
	| '{' '}'						{ *((HStoreValue**)result) = NULL; }
	| '[' ']'						{ *((HStoreValue**)result) = NULL; }
	| /* EMPTY */					{ *((HStoreValue**)result) = NULL; }
	;

array:
	'{' array_list '}'				{ $$ = makeHStoreValueArray($2); }
	| '[' array_list ']'			{ $$ = makeHStoreValueArray($2); }
	;

nil:
	NULL_P							{ $$ = $1; }
	| '{' '}'						{ $$.val = strdup("NULL"); $$.len = $$.total = 4; }
	| '[' ']'						{ $$.val = strdup("NULL"); $$.len = $$.total = 4; }
	;

array_list:
	nil								{ $$ = lappend(NIL, makeHStoreValueString(NULL, NULL)); }
	| STRING_P						{ $$ = lappend(NIL, makeHStoreValueString(NULL, &$1)); }
	| array							{ $$ = lappend(NIL, $1); }
	| hstore						{ $$ = lappend(NIL, $1); }
	| array_list ',' nil			{ $$ = lappend($1, makeHStoreValueString(NULL, NULL)); }
	| array_list ',' STRING_P		{ $$ = lappend($1, makeHStoreValueString(NULL, &$3)); }
	| array_list ',' array		 	{ $$ = lappend($1, $3); }
	| array_list ',' hstore			{ $$ = lappend($1, $3); }
	;

hstore:
	'{' pair_list '}'				{ $$ = makeHStoreValuePairs($2); }	
	;

pair_list:
	pair							{ $$ = lappend(NIL, $1); }
	| pair_list ',' pair			{ $$ = lappend($1, $3); }
	;

pair:
	key DELIMITER_P nil				{ $$ = makeHStoreStringPair(&$1, NULL); }
	| key DELIMITER_P STRING_P		{ $$ = makeHStoreStringPair(&$1, &$3); } 
	| key DELIMITER_P hstore		{ $$ = makeHStorePair(&$1, $3); }
	| key DELIMITER_P array			{ $$ = makeHStorePair(&$1, $3); }
	;

key:
	STRING_P						{ $$ = $1; }
	| NULL_P						{ $$ = $1; }
	;

%%

#include "hstore_scan.c"
