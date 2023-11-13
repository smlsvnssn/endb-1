use libc::{c_char, c_void};
use std::ffi::{CStr, CString};

use arrow2::ffi::ArrowArrayStream;
use chumsky::Parser;
use endb_arrow::arrow;
use endb_parser::parser::ast::Ast;
use endb_parser::parser::sql_parser;
use endb_parser::{SQL_AST_PARSER_NO_ERRORS, SQL_AST_PARSER_WITH_ERRORS};

use std::panic;

fn string_callback<T: Into<Vec<u8>>>(s: T, cb: extern "C" fn(*const c_char)) {
    let c_string = CString::new(s).unwrap();
    cb(c_string.as_ptr());
}

#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn endb_parse_sql(
    input: *const c_char,
    on_success: extern "C" fn(&Ast),
    on_error: extern "C" fn(*const c_char),
) {
    if let Err(err) = panic::catch_unwind(|| {
        SQL_AST_PARSER_NO_ERRORS.with(|parser| {
            let c_str = unsafe { CStr::from_ptr(input) };
            let input_str = c_str.to_str().unwrap();
            let result = parser.parse(input_str);
            if result.has_output() {
                on_success(&result.into_output().unwrap());
            } else {
                SQL_AST_PARSER_WITH_ERRORS.with(|parser| {
                    let result = parser.parse(input_str);
                    let error_string =
                        sql_parser::parse_errors_to_string(input_str, result.into_errors());
                    string_callback(error_string, on_error);
                });
            }
        })
    }) {
        let msg = err.downcast_ref::<&str>().unwrap_or(&"unknown panic!!");
        string_callback(msg.to_string(), on_error);
    }
}

#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn endb_annotate_input_with_error(
    input: *const c_char,
    message: *const c_char,
    start: usize,
    end: usize,
    on_success: extern "C" fn(*const c_char),
    on_error: extern "C" fn(*const c_char),
) {
    if let Err(err) = panic::catch_unwind(|| {
        let c_str = unsafe { CStr::from_ptr(input) };
        let input_str = c_str.to_str().unwrap();

        let c_str = unsafe { CStr::from_ptr(message) };
        let message_str = c_str.to_str().unwrap();

        let error_string =
            sql_parser::annotate_input_with_error(input_str, message_str, start, end);
        string_callback(error_string, on_success);
    }) {
        let msg = err.downcast_ref::<&str>().unwrap_or(&"unknown panic!!");
        string_callback(msg.to_string(), on_error);
    }
}

#[no_mangle]
pub extern "C" fn endb_ast_vec_len(ast: &Vec<Ast>) -> usize {
    ast.len()
}

#[no_mangle]
pub extern "C" fn endb_ast_vec_ptr(ast: &Vec<Ast>) -> *const Ast {
    ast.as_ptr()
}

#[no_mangle]
pub extern "C" fn endb_ast_size() -> usize {
    std::mem::size_of::<Ast>()
}

#[no_mangle]
#[allow(clippy::ptr_arg)]
pub extern "C" fn endb_ast_vec_element(ast: &Vec<Ast>, idx: usize) -> *const Ast {
    &ast[idx]
}

#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn endb_arrow_array_stream_producer(
    stream: &mut ArrowArrayStream,
    buffer_ptr: *const u8,
    buffer_size: usize,
    on_error: extern "C" fn(*const c_char),
) {
    match panic::catch_unwind(|| {
        let buffer = unsafe { std::slice::from_raw_parts(buffer_ptr, buffer_size) };
        arrow::read_arrow_array_stream_from_ipc_buffer(buffer)
    }) {
        Ok(Ok(exported_stream)) => unsafe {
            std::ptr::write(stream, exported_stream);
        },
        Ok(Err(err)) => {
            string_callback(err.to_string(), on_error);
        }
        Err(err) => {
            let msg = err.downcast_ref::<&str>().unwrap_or(&"unknown panic!!");
            string_callback(msg.to_string(), on_error);
        }
    }
}

#[no_mangle]
pub extern "C" fn endb_arrow_array_stream_consumer(
    init_stream: extern "C" fn(&mut ArrowArrayStream),
    on_success: extern "C" fn(*const u8, usize),
    on_error: extern "C" fn(*const c_char),
) {
    match panic::catch_unwind(|| {
        let mut stream = ArrowArrayStream::empty();
        init_stream(&mut stream);
        arrow::write_arrow_array_stream_to_ipc_buffer(stream)
    }) {
        Ok(Ok(buffer)) => on_success(buffer.as_ptr(), buffer.len()),
        Ok(Err(err)) => {
            string_callback(err.to_string(), on_error);
        }
        Err(err) => {
            let msg = err.downcast_ref::<&str>().unwrap_or(&"unknown panic!!");
            string_callback(msg.to_string(), on_error);
        }
    }
}

#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn endb_parse_sql_cst(
    filename: *const c_char,
    input: *const c_char,
    on_open: extern "C" fn(*const u8, usize),
    on_close: extern "C" fn(),
    on_literal: extern "C" fn(*const u8, usize, usize, usize),
    on_pattern: extern "C" fn(usize, usize),
    on_error: extern "C" fn(*const c_char),
) {
    if let Err(err) = panic::catch_unwind(|| {
        let c_str = unsafe { CStr::from_ptr(filename) };
        let filename_str = c_str.to_str().unwrap();
        let c_str = unsafe { CStr::from_ptr(input) };
        let input_str = c_str.to_str().unwrap();

        let mut state = endb_cst::ParseState::default();

        match endb_cst::sql::sql_stmt_list(input_str, 0, &mut state) {
            Ok(_) => {
                for e in state.events {
                    match e {
                        endb_cst::Event::Open { label, .. } => {
                            on_open(label.as_ptr(), label.len());
                        }
                        endb_cst::Event::Close {} => {
                            on_close();
                        }
                        endb_cst::Event::Literal { literal, range } => {
                            on_literal(literal.as_ptr(), literal.len(), range.start, range.end);
                        }
                        endb_cst::Event::Pattern { range, .. } => {
                            on_pattern(range.start, range.end);
                        }
                        endb_cst::Event::Error { .. } => {}
                    }
                }
            }
            Err(_) => {
                let mut state = endb_cst::ParseState {
                    track_errors: true,
                    ..endb_cst::ParseState::default()
                };
                let _ = endb_cst::sql::sql_stmt_list(input_str, 0, &mut state);

                string_callback(
                    endb_cst::parse_errors_to_string(
                        filename_str,
                        input_str,
                        &endb_cst::events_to_errors(&state.errors),
                    )
                    .unwrap(),
                    on_error,
                );
            }
        }
    }) {
        let msg = err.downcast_ref::<&str>().unwrap_or(&"unknown panic!!");
        string_callback(msg.to_string(), on_error);
    }
}

#[no_mangle]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn endb_render_json_error_report(
    report_json: *const c_char,
    on_success: extern "C" fn(*const c_char),
    on_error: extern "C" fn(*const c_char),
) {
    if let Err(err) = panic::catch_unwind(|| {
        let c_str = unsafe { CStr::from_ptr(report_json) };
        let report_json_str = c_str.to_str().unwrap();

        match endb_cst::json_error_report_to_string(report_json_str) {
            Ok(report) => {
                string_callback(report, on_success);
            }
            Err(err) => string_callback(err.to_string(), on_error),
        }
    }) {
        let msg = err.downcast_ref::<&str>().unwrap_or(&"unknown panic!!");
        string_callback(msg.to_string(), on_error);
    }
}

#[no_mangle]
pub extern "C" fn endb_init_logger() {
    endb_server::init_logger();
}

fn do_log(level: log::Level, target: *const c_char, message: *const c_char) {
    let c_str = unsafe { CStr::from_ptr(target) };
    let target_str = c_str.to_str().unwrap();
    let c_str = unsafe { CStr::from_ptr(message) };
    let message_str = c_str.to_str().unwrap();

    log::log!(target: target_str, level, "{}", message_str);
}

#[no_mangle]
pub extern "C" fn endb_log_error(target: *const c_char, message: *const c_char) {
    do_log(log::Level::Error, target, message);
}

#[no_mangle]
pub extern "C" fn endb_log_warn(target: *const c_char, message: *const c_char) {
    do_log(log::Level::Warn, target, message);
}

#[no_mangle]
pub extern "C" fn endb_log_info(target: *const c_char, message: *const c_char) {
    do_log(log::Level::Info, target, message);
}

#[no_mangle]
pub extern "C" fn endb_log_debug(target: *const c_char, message: *const c_char) {
    do_log(log::Level::Debug, target, message);
}

#[no_mangle]
pub extern "C" fn endb_log_trace(target: *const c_char, message: *const c_char) {
    do_log(log::Level::Trace, target, message);
}

#[no_mangle]
pub extern "C" fn endb_start_server(
    on_init: extern "C" fn(*const c_char),
    on_query: extern "C" fn(
        *mut c_void,
        *const c_char,
        *const c_char,
        *const c_char,
        *const c_char,
        *const c_char,
        extern "C" fn(*mut c_void, u16, *const c_char, *const c_char),
    ),
    on_error: extern "C" fn(*const c_char),
) {
    match panic::catch_unwind(|| {
        endb_server::start_server(
            |config_json| {
                string_callback(config_json, on_init);
            },
            move |response, method, media_type, q, p, m| {
                let method_cstring = CString::new(method).unwrap();
                let media_type_cstring = CString::new(media_type).unwrap();
                let q_cstring = CString::new(q).unwrap();
                let p_cstring = CString::new(p).unwrap();
                let m_cstring = CString::new(m).unwrap();

                extern "C" fn on_response_callback(
                    response: *mut c_void,
                    status: u16,
                    content_type: *const c_char,
                    body: *const c_char,
                ) {
                    let c_str = unsafe { CStr::from_ptr(content_type) };
                    let content_type_str = c_str.to_str().unwrap();
                    let c_str = unsafe { CStr::from_ptr(body) };
                    let body_str = c_str.to_str().unwrap();

                    let response = unsafe { &mut *(response as *mut endb_server::HttpResponse) };

                    endb_server::on_response(response, status, content_type_str, body_str);
                }
                on_query(
                    response as *mut _ as *mut c_void,
                    method_cstring.as_ptr(),
                    media_type_cstring.as_ptr(),
                    q_cstring.as_ptr(),
                    p_cstring.as_ptr(),
                    m_cstring.as_ptr(),
                    on_response_callback,
                );
            },
        )
    }) {
        Err(err) => {
            let msg = err.downcast_ref::<&str>().unwrap_or(&"unknown panic!!");
            string_callback(msg.to_string(), on_error);
        }
        Ok(Err(err)) => {
            string_callback(err.to_string(), on_error);
        }
        _ => {}
    }
}
