/*
Copyright (c) 2013-2015, Alexey Savelyev <info@homeweb.ru>
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Based on source code from http://www.ols.es/exim/dlext/ by David Saez <david@ols.es>,
source code of exim by Philip Hazel <ph10@cam.ac.uk>
and source code of exiscan by Tom Kistner <tom@duncanthrax.net>
and source code of Victor Ustugov http://mta.org.ua/
*/

#include "exim.h"

#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <stdarg.h>
#include <errno.h>
#include <cJSON.h>

#define RSPAMD_TIMEOUT		120

extern uschar *tod_stamp(int);

int strpos(char *hay, char *needle, int offset)
{
   char haystack[strlen(hay)];
   strncpy(haystack, hay+offset, strlen(hay)-offset);
   char *p = strstr(haystack, needle);
   if (p)
      return p - haystack+offset;
   return -1;
}

int rspamd(uschar **yield, int argc, uschar *argv[]) {
    char	*arg_socket_addr;
    char	*arg_defer_ok;
    int		defer_ok;
    int		rspamd_command;
    char	tcp_addr[15];
    int		tcp_port;
    FILE	*mbox_file = NULL;
    off_t	mbox_size;
    uschar	*s, *p;
    header_line *my_header, *header_new, *header_last, *tmp_headerlist;
    header_line *last_received = NULL;
    uschar      *address;
    uschar	*helo;
    uschar	*sender_host_name;
    uschar	*authenticated_id;
    char	mbox_path[512];
    int		max_len, len;
    int		rspamd_sock = 0;
    struct	hostent *he;
    struct	in_addr in;
    struct	sockaddr_un server;
#ifndef NO_POLL_H
    int result;
    struct pollfd pollfd;
#endif
    int		offset;
    uschar	spamd_buffer[32600];
    uschar	spamd_buffer2[32600];
    time_t	start;
    size_t	read, wrote;
    int		i, j, c;

    arg_socket_addr = argv[0];
    arg_defer_ok = argv[1];

    if (argc < 2) {
	defer_ok = 0;
    } else if (
	    (strcmpic(arg_defer_ok,US"1") == 0)
	|| (strcmpic(arg_defer_ok,US"yes") == 0)
	|| (strcmpic(arg_defer_ok,US"true") == 0)
	|| (strcmpic(arg_defer_ok,US"defer_ok") == 0)
	) {
	defer_ok = 1;
    } else {
	defer_ok = 0;
    }
debug_printf("  defer_ok: %d\n", defer_ok);

    if ((arg_socket_addr == NULL) || (arg_socket_addr[0] == 0)) {
	log_write(0, LOG_MAIN|LOG_PANIC,
	    "rspamd dlfunc: Socket address expected");
	*yield = string_sprintf("rspamd dlfunc: Socket address expected");
	goto RETURN_DEFER;
    }

// get message body stream

    if (split_spool_directory == 0) {
	sprintf(mbox_path, "%s/input/%s-D", spool_directory, message_id);
    } else {
	sprintf(mbox_path, "%s/input/%s/%s-D", spool_directory, message_subdir, message_id);
    }
debug_printf("  Open spool file: %s\n", mbox_path);
    mbox_file = fopen(mbox_path,"rb");

    if (!mbox_file) {
	*yield = string_sprintf("rspamd dlfunc: Unable to spool message '%s'", mbox_path);
	return(defer_ok ? OK : ERROR);
    }

    (void)fseek(mbox_file, 0, SEEK_END);
    mbox_size = ftell(mbox_file);
debug_printf("  Total spool file size: %d\n", mbox_size);
    mbox_size -= SPOOL_DATA_START_OFFSET;
debug_printf("  Spool file size: %d\n", mbox_size);
debug_printf("  fseek %d, %d\n", SPOOL_DATA_START_OFFSET, SEEK_SET);
    (void)fseek(mbox_file, SPOOL_DATA_START_OFFSET, SEEK_SET);

    start = time(NULL);
/* socket does not start with '/' -> network socket */
    if (arg_socket_addr[0] != '/') {
	if (sscanf(CS arg_socket_addr, "%s %u", tcp_addr, &tcp_port) != 2 ) {
	    log_write(0, LOG_MAIN|LOG_PANIC,
		"rspamd dlfunc: Invalid rspamd address: '%s'", arg_socket_addr);
	    *yield = string_sprintf("rspamd dlfunc: Invalid rspamd address: '%s'", arg_socket_addr);
	    goto RETURN_DEFER;
	}

	/* Lookup the host */
	if((he = gethostbyname(CS tcp_addr)) == 0) {
	    log_write(0, LOG_MAIN|LOG_PANIC,
		"rspamd dlfunc: failed to lookup host '%s'", tcp_addr);
	    *yield = string_sprintf("rspamd dlfunc: failed to lookup host '%s'", tcp_addr);
	    goto RETURN_DEFER;
	}

	in = *(struct in_addr *) he->h_addr_list[0];

/* contact a rspamd */

	if ((rspamd_sock = ip_socket(SOCK_STREAM, AF_INET)) < 0) {
	    log_write(0, LOG_MAIN|LOG_PANIC,
		"rspamd dlfunc: TCP socket creation failed: %s", strerror(errno));
	    *yield = string_sprintf("rspamd dlfunc: TCP socket creation failed: %s", strerror(errno));
	    goto RETURN_DEFER;
	};

	if (ip_connect(rspamd_sock, AF_INET, (uschar*)inet_ntoa(in), tcp_port, 5, FALSE) < 0) {
	    log_write(0, LOG_MAIN|LOG_PANIC,
		"rspamd dlfunc: connection to %s, port %u failed: %s", tcp_addr, tcp_port, strerror(errno));
	    *yield = string_sprintf("rspamd dlfunc: connection to %s, port %u failed: %s", tcp_addr, tcp_port, strerror(errno));
	    goto RETURN_DEFER;
	}

debug_printf("  Use TCP socket %s:%d\n", tcp_addr, tcp_port);
    } else {
	if ((rspamd_sock = socket(AF_UNIX, SOCK_STREAM, 0)) < 0) {
	    log_write(0, LOG_MAIN|LOG_PANIC,
		"rspamd dlfunc: Unable to acquire socket (%s)", strerror(errno));
	    *yield = string_sprintf("rspamd dlfunc: Unable to acquire socket (%s)", strerror(errno));
	    goto RETURN_DEFER;
	}

	server.sun_family = AF_UNIX;
	Ustrcpy(server.sun_path, arg_socket_addr);

	if (connect(rspamd_sock, (struct sockaddr *) &server, sizeof(struct sockaddr_un)) < 0) {
	    log_write(0, LOG_MAIN|LOG_PANIC,
		"rspamd dlfunc: Unable to connect to UNIX socket %s (%s)", socket, strerror(errno) );
	    *yield = string_sprintf("rspamd dlfunc: Unable to connect to UNIX socket %s (%s)", socket, strerror(errno) );
	    goto RETURN_DEFER;
	}

debug_printf("  Use UNIX Domain socket %s\n", arg_socket_addr);
    }

// now we are connected to rspamd on rspamd_sock

    memset(spamd_buffer2, 0, sizeof(spamd_buffer2));
    offset = 0;

    address = expand_string(US"${sender_address}");

    if (address && *address) {
	s = string_sprintf("Return-path: <%s>\n", address);
	max_len = sizeof(spamd_buffer2) - offset - 1;
	len = Ustrlen(s);
	if (len > max_len) len = max_len;
        Ustrncpy(spamd_buffer2 + offset, s, len);
	offset += len;
    }

//    address = expand_string(US"${if def:received_for{$received_for}}");
    address = expand_string(US"${received_for}");
    if (!address || !*address) address = expand_string(US"${recipients}");
    if (!address || !*address) address = expand_string(US"${local_part}@${domain}");

    if (address && *address) {
	s = string_sprintf("Envelope-To: %s\n", address);
	max_len = sizeof(spamd_buffer2) - offset - 1;
	len = Ustrlen(s);
	if (len > max_len) len = max_len;
	Ustrncpy(spamd_buffer2 + offset, s, len);
	offset += len;
    }

    s = string_sprintf("Delivery-date: %s\n", tod_stamp(tod_full));
    max_len = sizeof(spamd_buffer2) - offset - 1;
    len = Ustrlen(s);
    if (len > max_len) len = max_len;
    Ustrncpy(spamd_buffer2 + offset, s, len);
    offset += len;

    // create links to original headers list
    tmp_headerlist = NULL;
    header_last = NULL;
    for (my_header = header_list; my_header; my_header = my_header->next) {
	if ((my_header->type != '*') && (my_header->type != htype_old)) {

	    header_new = store_get(sizeof(header_line));

////	    header_new->text = string_copyn(my_header->text, my_header->slen);
//	    header_new->text = store_get(my_header->slen);
//	    memcpy(header_new->text, my_header->text, my_header->slen);
	    header_new->text = my_header->text;

	    header_new->slen = my_header->slen;
	    header_new->type = my_header->type;
	    header_new->next = NULL;
//debug_printf("  create a copy of header item: '%s'\n", header_new->text);

	    if (tmp_headerlist == NULL) tmp_headerlist = header_new;
	    if (header_last != NULL) header_last->next = header_new;
	    header_last = header_new;
	}
    }

#ifdef WITH_EXPERIMENTAL_REMOVE_HEADER
    // headers removed by acl_check_data
    if (acl_removed_headers != NULL) {
	for (my_header = tmp_headerlist; my_header != NULL; my_header = my_header->next) {
	    uschar *list;

	    list = acl_removed_headers;

	    int sep = ':';         // This is specified as a colon-separated list
	    uschar buffer[128];
	    while ((s = string_nextinlist(&list, &sep, buffer, sizeof(buffer))) != NULL) {
		int len = Ustrlen(s);
		if (header_testname(my_header, s, len, FALSE)) {
//debug_printf("  header removed by acl_check_data: '%s'; '%s'\n", s, my_header->text);
		    my_header->type = htype_old;
		}
	    }
	}
    }
#endif

    // headers added by acl_check_data
    my_header = acl_added_headers;
    while (my_header != NULL) {
//debug_printf("  header added by acl_check_data: '%s'\n", my_header->text);

	header_new = store_get(sizeof(header_line));

////	header_new->text = string_copyn(my_header->text, my_header->slen);
//	header_new->text = store_get(my_header->slen);
//	memcpy(header_new->text, my_header->text, my_header->slen);
	header_new->text = my_header->text;

	header_new->slen = my_header->slen;

	switch(my_header->type) {
	case htype_add_top:
	// add header at top
	    header_new->next = tmp_headerlist;
	    tmp_headerlist = header_new;
	    break;

	case htype_add_rec:
	// add header after Received:
	    if (last_received == NULL) {
		last_received = tmp_headerlist;
		while (!header_testname(last_received, US"Received", 8, FALSE))
		    last_received = last_received->next;
		while (last_received->next != NULL && header_testname(last_received->next, US"Received", 8, FALSE))
		    last_received = last_received->next;
	    }
	    header_new->next = last_received->next;
	    last_received->next = header_new;
	    break;

	case htype_add_rfc:
	// add header before any header which is NOT Received: or Resent-
	    last_received = tmp_headerlist;
	    while ( (last_received->next != NULL) &&
	    ( (header_testname(last_received->next, US"Received", 8, FALSE)) ||
		(header_testname_incomplete(last_received->next, US"Resent-", 7, FALSE)) ) )
		last_received = last_received->next;
	// last_received now points to the last Received: or Resent-* header
	// in an uninterrupted chain of those header types (seen from the beginning
	// of all headers. Our current header must follow it.
	    header_new->next = last_received->next;
	    last_received->next = header_new;
	    break;

	default:
	// htype_add_bot
	// add header at bottom
	    header_new->next = NULL;
	    header_last->next = header_new;
	    break;
	}

	if (header_new->next == NULL) header_last = header_new;

	my_header = my_header->next;
    }

    // copy all the headers to data buffer
    my_header = tmp_headerlist;
    while (my_header) {
	if ((my_header->type != '*') && (my_header->type != htype_old)) {
	    max_len = sizeof(spamd_buffer2) - offset - 1;
	    len = my_header->slen;
	    if (len > max_len) len = max_len;
	    Ustrncpy(spamd_buffer2 + offset, my_header->text, len);
	    offset += len;
//debug_printf("  copy header item: '%s'\n", my_header->text);
	}

////	if (my_header->text) store_release(my_header->text);
	header_last = my_header;
	my_header = my_header->next;
//	if (header_last) store_release(header_last);
    }

//    s = string_sprintf("\r\n");
    s = string_sprintf("\n");
    max_len = sizeof(spamd_buffer2) - offset - 1;
    len = Ustrlen(s);
    if (len > max_len) len = max_len;
    Ustrncpy(spamd_buffer2 + offset, s, len);
    offset += len;

debug_printf("  Headers size: %d\n", offset);
    mbox_size += offset;
debug_printf("  Total message size: %d\n", mbox_size);

// copy request to buffer
    memset(spamd_buffer, 0, sizeof(spamd_buffer));
    string_format(spamd_buffer,
	sizeof(spamd_buffer),
	"POST /checkv2 HTTP/1.0\r\nContent-length: " OFF_T_FMT "\r\nPass: all\r\nQueue-Id: %s\r\nFrom: %s\r\nRecipient-Number: %d\r\n",
	mbox_size, message_id, sender_address, recipients_count);
    for (i = 0; i < recipients_count; i ++)
	string_format(spamd_buffer+Ustrlen(spamd_buffer), sizeof(spamd_buffer)-Ustrlen(spamd_buffer), "Rcpt: %s\r\n", recipients_list[i].address);
    if ((helo = expand_string(US"$sender_helo_name")) != NULL && *helo != '\0')
	string_format(spamd_buffer+Ustrlen(spamd_buffer), sizeof(spamd_buffer)-Ustrlen(spamd_buffer), "Helo: %s\r\n", helo);

    if ((sender_host_name = expand_string(US"$sender_host_name")) != NULL && *sender_host_name != '\0')
	 string_format(spamd_buffer+Ustrlen(spamd_buffer), sizeof(spamd_buffer)-Ustrlen(spamd_buffer), "Hostname: %s\r\n", sender_host_name);
	  //else
	   //string_format(spamd_buffer+Ustrlen(spamd_buffer), sizeof(spamd_buffer)-Ustrlen(spamd_buffer), "Hostname: unknown\r\n");

    if (sender_host_address != NULL)
		
	string_format(spamd_buffer+Ustrlen(spamd_buffer), sizeof(spamd_buffer)-Ustrlen(spamd_buffer), "IP: %s\r\n", sender_host_address);
	string_format(spamd_buffer+Ustrlen(spamd_buffer), sizeof(spamd_buffer)-Ustrlen(spamd_buffer), "Pass: all\r\n");

	//authenticated_id
	if ((authenticated_id = expand_string(US"$authenticated_id")) != NULL && *authenticated_id != '\0')
	 string_format(spamd_buffer+Ustrlen(spamd_buffer), sizeof(spamd_buffer)-Ustrlen(spamd_buffer), "User: %s\r\n", authenticated_id);

    string_format(spamd_buffer+Ustrlen(spamd_buffer), sizeof(spamd_buffer)-Ustrlen(spamd_buffer), "\r\n");

debug_printf("  Send to socket: %s", spamd_buffer);
// send our request
    if (send(rspamd_sock, spamd_buffer, Ustrlen(spamd_buffer), 0) < 0) {
	log_write(0, LOG_MAIN|LOG_PANIC,
	    "rspamd dlfunc: rspamd send failed: %s", strerror(errno));
	goto RETURN_DEFER;
    }

  /*
   * now send the data buffer and spool file
   */

    Ustrcpy(big_buffer, "sending data block");
debug_printf("sending data block\n");

debug_printf("  Send to socket: %s", spamd_buffer2);
    wrote = send(rspamd_sock, spamd_buffer2, strlen(spamd_buffer2), 0);
    if (wrote == -1) goto WRITE_FAILED;
debug_printf("  wrote to socket %d bytes\n", wrote);

  /*
   * Note: poll() is not supported in OSX 10.2.
   */

#ifndef NO_POLL_H
    pollfd.fd = rspamd_sock;
    pollfd.events = POLLOUT;
#endif
//    (void)fcntl(rspamd_sock, F_SETFL, O_NONBLOCK);
    do {
        read = fread(spamd_buffer,1,sizeof(spamd_buffer),mbox_file);
if (read < sizeof(spamd_buffer)) spamd_buffer[read] = 0;
debug_printf("  Read from spool file: %s", spamd_buffer);
        if (read > 0) {
	    offset = 0;
again:

#ifndef NO_POLL_H
	    result = poll(&pollfd, 1, 1000);
	    if (result == -1 && errno == EINTR)
		continue;
	    else if (result < 1) {
		if (result == -1)
		    log_write(0, LOG_MAIN|LOG_PANIC,
		        "rspamd dlfunc: %s on rspamd socket", strerror(errno));
		else {
		    if (time(NULL) - start < RSPAMD_TIMEOUT)
			goto again;
		    log_write(0, LOG_MAIN|LOG_PANIC,
			"rspamd dlfunc: timed out writing rspamd socket");
		    *yield = string_sprintf("rspamd dlfunc: timed out writing rspamd socket");
		}
		goto RETURN_DEFER;
	    }
#endif
	    wrote = send(rspamd_sock, spamd_buffer + offset, read - offset, 0);
debug_printf("  Send to socket %d bytes: %s", read - offset, spamd_buffer + offset);
debug_printf("  wrote to socket %d bytes\n", wrote);
	    if (wrote == -1) goto WRITE_FAILED;
	    if (offset + wrote != read) {
		offset += wrote;
		goto again;
	    }
	}
    } while (!feof(mbox_file) && !ferror(mbox_file));

    if (ferror(mbox_file)) {
	log_write(0, LOG_MAIN|LOG_PANIC,
	    "rspamd dlfunc: error reading spool file: %s", strerror(errno));
	*yield = string_sprintf("rspamd dlfunc: error reading spool file: %s", strerror(errno));
	goto RETURN_DEFER;
    }

  /*
   read rspamd response using what's left of the timeout.
   */

debug_printf("read rspamd response using what's left of the timeout (%d sec)\n", RSPAMD_TIMEOUT - time(NULL) + start);

    memset(spamd_buffer, 0, sizeof(spamd_buffer));
    offset = 0;
    while ((i = ip_recv(rspamd_sock,
		spamd_buffer + offset,
		sizeof(spamd_buffer) - offset - 1,
	RSPAMD_TIMEOUT - time(NULL) + start)) > 0
    ) {
		debug_printf("  read %d bytes from socket\n", i);
		offset += i;
    }
debug_printf("  total read %d bytes from socket\n", offset);

/* error handling */
    if((i <= 0) && (errno != 0)) {
	log_write(0, LOG_MAIN|LOG_PANIC,
	    "rspamd dlfunc: error reading from rspamd socket: %s", strerror(errno));
	*yield = string_sprintf("rspamd dlfunc: error reading from rspamd socket: %s", strerror(errno));
	goto RETURN_DEFER;
    }

debug_printf("read from socket: %s\n", spamd_buffer);

    if (rspamd_sock > 0) {
	(void)close(rspamd_sock);
	rspamd_sock = 0;
    }
    if (mbox_file != NULL) {
		(void)fclose(mbox_file);
		mbox_file = NULL;
    }

    //Parse http response code
	if (strstr(spamd_buffer, "HTTP/1.1 200 OK") == NULL && strstr(spamd_buffer, "HTTP/1.0 200 OK") == NULL)  {
		*yield = string_sprintf("rspamd dlfunc: HTTP return code != 200: %s", spamd_buffer);
		goto RETURN_DEFER;
	}
	
	//Parse http response
	int pos = strpos(spamd_buffer, "\r\n\r\n", 0);
	if (pos == -1)  {
		*yield = string_sprintf("rspamd dlfunc: HTTP response error: %s", spamd_buffer);
		goto RETURN_DEFER;
	}
	char *json_answer = string_sprintf("%s", spamd_buffer +pos+4);
	
	//Parse json
	cJSON *json = NULL;		
	json = cJSON_Parse(json_answer);
	
	if (!json)  {
		*yield = string_sprintf("rspamd dlfunc: Json parse error, json: %s", spamd_buffer);
		goto RETURN_DEFER;
	}
	
	//Score
	cJSON *score = cJSON_GetObjectItem(json, "score");
	if(!cJSON_IsNumber(score)) {
		*yield = string_sprintf("rspamd dlfunc: Json parse error, no found 'score'");
		goto RETURN_DEFER;
	}
	//required_score
	cJSON *required_score = cJSON_GetObjectItem(json, "required_score");
	if(!cJSON_IsNumber(required_score)) {
		*yield = string_sprintf("rspamd dlfunc: Json parse error, no found 'required_score'");
		goto RETURN_DEFER;
	}
	//Action
	cJSON *action = cJSON_GetObjectItem(json, "action");
	if(!cJSON_IsString(action)) {
		*yield = string_sprintf("rspamd dlfunc: Json parse error, no found 'action'");
		goto RETURN_DEFER;
	}
	*yield = string_sprintf("[%.2f / %.2f]", score->valuedouble, required_score->valuedouble);
	
	//Parse scan time
	cJSON *time_real = cJSON_GetObjectItem(json, "time_real");
	cJSON *time_virtual = cJSON_GetObjectItem(json, "time_virtual");
	if(cJSON_IsNumber(time_real) && cJSON_IsNumber(time_virtual)) *yield = string_sprintf("%s  [time: %.6f, %.6f]", *yield, time_real->valuedouble, time_virtual->valuedouble);
		
	*yield = string_sprintf("%s\n Action: %s\n", *yield, action->valuestring);	
		
	cJSON *symbol = NULL;
	cJSON *symbol_name = NULL;
	cJSON *symbol_score = NULL;
	cJSON *symbol_options = NULL;
	cJSON *option = NULL;
	
	//parse symbols
	cJSON *symbols = cJSON_GetObjectItem(json, "symbols");	
	for(i=0; i<cJSON_GetArraySize(symbols); i++) {
		symbol = cJSON_GetArrayItem(symbols, i);
		symbol_name = cJSON_GetObjectItem(symbol, "name");
		symbol_score = cJSON_GetObjectItem(symbol, "score");
		symbol_options = cJSON_GetObjectItem(symbol, "options");
		
		if(cJSON_IsString(symbol_name)) *yield = string_sprintf("%s %s", *yield, symbol_name->valuestring);
		if(cJSON_IsNumber(symbol_score)) *yield = string_sprintf("%s(%.2f)", *yield, symbol_score->valuedouble);
		
		//parse options
		c = cJSON_GetArraySize(symbol_options);		
		if(c > 0) *yield = string_sprintf("%s[", *yield);			
		for(j=0; j<c; j++) {
			option = cJSON_GetArrayItem(symbol_options, j);
			if(cJSON_IsString(option)) {
				*yield = string_sprintf("%s%s", *yield, option->valuestring);
				if(j < c-1) *yield = string_sprintf("%s, ", *yield);
			}
		}
		if(c > 0) *yield = string_sprintf("%s]", *yield);
		
		*yield = string_sprintf("%s\n", *yield);
	}
	
	//Parse messages
	cJSON *mess = NULL;
	cJSON *messages = cJSON_GetObjectItem(json, "messages");
	c = cJSON_GetArraySize(messages);
	for(i=0; i<c; i++) {
		mess = cJSON_GetArrayItem(messages, i);
		if(cJSON_IsString(mess)) *yield = string_sprintf("%s %s", *yield, mess->valuestring);
		if(i < c-1) *yield = string_sprintf("%s\n", *yield);
	}
	
    return OK;

/* Come here if any call to read_response, other than a response after the data
phase, failed. Analyse the error, and if isn't too bad, send a QUIT
command. Wait for the response with a short timeout, so we don't wind up this
process before the far end has had time to read the QUIT. */

WRITE_FAILED:
{
    log_write(0, LOG_MAIN|LOG_PANIC,
	"rspamd dlfunc: %s on rspamd socket", strerror(errno));
    *yield = string_sprintf("rspamd dlfunc: %s on rspamd socket", strerror(errno));
    goto RETURN_DEFER;
}

RESPONSE_FAILED:
{
    int code;
    int save_errno;
    int more_errno;
    uschar message_buffer[256];
    uschar *message;

    save_errno = errno;

    message = &message_buffer[0];

    log_write(0, LOG_MAIN|LOG_PANIC, "rspamd dlfunc: %s", message);
    *yield = string_sprintf("rspamd dlfunc: %s", message);

    goto RETURN_DEFER;
}

RETURN_DEFER:
{
    if (rspamd_sock > 0) {
	(void)close(rspamd_sock);
	rspamd_sock = 0;
    }
    if (mbox_file != NULL) {
	(void)fclose(mbox_file);
	mbox_file = NULL;
    }

    return(defer_ok ? OK : ERROR);
}

    return OK;
}
