#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef enum Keyword {
  Select,
  From,
  Where,
  GroupBy,
  Having,
  OrderBy,
  Lt,
  Le,
  Gt,
  Ge,
  Eq,
  Ne,
  Is,
  In,
  InQuery,
  Between,
  Like,
  Case,
  Exists,
  ScalarSubquery,
  Else,
  Plus,
  Minus,
  Mul,
  Div,
  Mod,
  Lsh,
  Rsh,
  And,
  Or,
  Not,
  Function,
  AggregateFunction,
  Count,
  CountStar,
  Avg,
  Sum,
  Min,
  Max,
  Total,
  GroupConcat,
  Cast,
  Asc,
  Desc,
  Distinct,
  All,
  True,
  False,
  Null,
  Limit,
  Offset,
  Join,
  Type,
  Left,
  Inner,
  On,
  Except,
  Intersect,
  Union,
  UnionAll,
  Values,
  Insert,
  ColumnNames,
  Delete,
  Update,
  CreateIndex,
  DropIndex,
  CreateView,
  DropView,
  IfExists,
  CreateTable,
  DropTable,
} Keyword;

typedef struct Vec_Ast Vec_Ast;

typedef enum Ast_Tag {
  List,
  KW,
  Integer,
  Float,
  Id,
  String,
  Binary,
} Ast_Tag;

typedef struct Id_Body {
  int32_t start;
  int32_t end;
} Id_Body;

typedef struct String_Body {
  int32_t start;
  int32_t end;
} String_Body;

typedef struct Binary_Body {
  int32_t start;
  int32_t end;
} Binary_Body;

typedef struct Ast {
  Ast_Tag tag;
  union {
    struct {
      struct Vec_Ast list;
    };
    struct {
      enum Keyword kw;
    };
    struct {
      int64_t integer;
    };
    struct {
      double float_;
    };
    Id_Body id;
    String_Body string;
    Binary_Body binary;
  };
} Ast;

void endb_parse_sql(const char *input,
                    void (*on_success)(const struct Ast*),
                    void (*on_error)(const char*));

uintptr_t endb_ast_vec_len(const struct Vec_Ast *ast);

const struct Ast *endb_ast_vec_ptr(const struct Vec_Ast *ast);

uintptr_t endb_ast_size(void);

const struct Ast *endb_ast_vec_element(const struct Vec_Ast *ast, uintptr_t idx);