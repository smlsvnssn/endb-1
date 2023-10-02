use crate::{peg, Event, ParseErr, ParseErrorDescriptor, ParseResult, ParseState};

crate::peg! {
    (<whitespace> <- (TRIVIA "(\\s*|--[^\n\r]*?)*"));

    (<ident> <- (RE "\\b\\p{XID_START}\\p{XID_CONTINUE}*\\b"));

    (numeric_literal <- (RE "\\b(0[xX][0-9A-Fa-f]+|[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)?)\\b"));
    (string_literal <- (RE "(\"(?:\\\"|[^\"])*?\"|'(?:''|[^'])*?')"));
    (blob_literal <- (RE "(\\b[xX]'[0-9A-Fa-f]*?'|[xX]\"[0-9A-Fa-f]*?\")"));

    (<literal> <- (/ numeric_literal string_literal blob_literal "NULL" "TRUE" "FALSE" "CURRENT_TIME" "CURRENT_DATE" "CURRENT_TIMESTAMP"));

    (bind_parameter <- (RE "\\b(:?\\?|:\\p{XID_START}\\p{XID_CONTINUE}*)\\b"));

    (function_name <- ident);
    (type_name <- ident);
    (column_name <- ident);

    (subquery <- "(" select_stmt ")");
    (paren_expr <- "(" expr ")");

    (cast_expr <- "CAST" (^ "(" expr "AS" type_name ")" ));
    (function_call_expr <- function_name "(" (/ ( (? "DISTINCT") (? expr (* "," expr ) ) ) "*" ) ")" (? "FILTER" (^ "(" "WHERE" expr ")" )));
    (exists_expr <- "EXISTS"  (^ subquery));
    (case_when_then_expr <- "WHEN" expr "THEN" expr);
    (case_expr <- "CASE" (^ (? (! "WHEN") expr ) (+ case_when_then_expr) (? "ELSE" expr ) "END" ));
    (column_reference <- (? table_name "." ) column_name);

    (<atom> <-
     (/
      literal
      bind_parameter
      subquery
      paren_expr
      cast_expr
      function_call_expr
      exists_expr
      case_expr
      column_reference
     ));

    (<unary> <- (* (/"+" "-" "~" )) atom);
    (<concat> <- unary (* "||" unary ));
    (<mul> <- concat (* (/ "*" "/" "%" ) concat ));
    (<add> <- mul (* (/ "+" "-" ) mul ));
    (<bit> <- add (* (/ "<<" ">>" "&" "|" ) add ));
    (<comp> <- bit (* (/ "<=" "<" ">=" ">" ) bit ));
    (<equal> <-
     comp (* (/
              ( (/ "==" "=" "!=" "<>" ) comp )
              ( (? "NOT") (/ ( "LIKE" (^ comp (? "ESCAPE" comp ) ) ) ( (/ "GLOB" "REGEXP" "MATCH" ) (^ comp))) )
              ( "IS" (^ (? "NOT") comp ) )
              ( (? "NOT") "BETWEEN" (^ comp "AND" comp ) )
              ( (? "NOT") "IN" (^ (/ ( "(" select_stmt ")" ) ( "(" expr (* "," expr ) ")" ) ( "(" ")" ))) )
     )));
    (<not> <- (* "NOT") equal);
    (<and> <- not (* "AND" not ));
    (<or> <- and (* "OR" and ));

    (expr <- or);

    (column_alias <- ident);
    (table_name <- ident);

    (qualified_asterisk <- table_name "." (^ "*" ));
    (asterisk <- "*");
    (invalid_column_alias <- (/ "FROM" "WHERE" "GROUP" "HAVING" "ORDER" "LIMIT" "UNION" "INTERSECT" "EXCEPT"));
    (result_column <- (/ ( expr (? (/ ( "AS" (^ column_alias) ) ( (! invalid_column_alias) column_alias ) ))) qualified_asterisk asterisk));

    (table_alias <- ident);

    (join_constraint <- "ON" expr );
    (join_operator <- (/ "," ( (? (/ ( "LEFT" (? "OUTER") ) "INNER" "CROSS" )) "JOIN")));
    (join_clause <- table_or_subquery (* join_operator table_or_subquery (? join_constraint )));
    (invalid_table_alias <- (/ "LEFT" "INNER" "CROSS" "JOIN" "WHERE" "GROUP" "HAVING" "ORDER" "LIMIT" "ON" "UNION" "INTERSECT" "EXCEPT"));
    (table_or_subquery <- (/ ( table_name (? (/ ( "AS" (^ table_alias) )
                                              ( !invalid_table_alias table_alias ) ) ) )
                           ( "(" select_stmt ")" "AS" table_alias )
                           ( "(" join_clause ")")));

    (from_clause <- "FROM" (/ ( table_or_subquery (* "," table_or_subquery ) ) join_clause ));
    (where_clause <- "WHERE" expr);
    (group_by_clause <- "GROUP" "BY" expr (*  "," expr ));
    (having_clause <-  "HAVING" expr);

    (select_core <- (/
                     ( "SELECT" (? (/ "ALL" "DISTINCT" )) ( result_column (* "," result_column ) )
                        (? from_clause)
                        (? where_clause)
                        (? group_by_clause)
                        (? having_clause ) )
                     ( "VALUES" "(" expr (* "," expr) ")" (* "," "(" expr (* "," expr) ")" ) )));

    (compound_operator <- (/ ( "UNION" "ALL" ) "UNION" "INTERSECT" "EXCEPT"));
    (common_table_expression <- table_name (? "(" column_name (* "," column_name ) ")" ) "AS" "(" select_stmt ")");

    (with_clause <- "WITH" (? "RECURSIVE") common_table_expression (* "," common_table_expression ));

    (ordering_term <- expr (? (/ "ASC" "DESC" )));
    (order_by_clause <- "ORDER" "BY" ordering_term (* ( "," ordering_term )));

    (limit_offset_clause <- "LIMIT" expr (? (/ "," "OFFSET" ) expr ));

    (select_stmt <-
     (? with_clause)
     select_core (* compound_operator select_core )
     (? order_by_clause)
     (? limit_offset_clause));

    (sql_stmt <- select_stmt);
    (sql_stmt_list <- whitespace sql_stmt (* ";" sql_stmt ) (? ";") (! (TRIVIA ".")));
}