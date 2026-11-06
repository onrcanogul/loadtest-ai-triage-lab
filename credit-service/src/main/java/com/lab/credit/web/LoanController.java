package com.lab.credit.web;

import com.lab.credit.service.LoanApplicationService;
import com.lab.credit.web.dto.LoanApplicationRequest;
import com.lab.credit.web.dto.LoanApplicationResponse;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/loans")
public class LoanController {

    private final LoanApplicationService service;

    public LoanController(LoanApplicationService service) {
        this.service = service;
    }

    @PostMapping("/shopping/apply")
    @ResponseStatus(HttpStatus.CREATED)
    public LoanApplicationResponse apply(@Valid @RequestBody LoanApplicationRequest request) {
        return LoanApplicationResponse.from(service.apply(request));
    }

    @GetMapping("/{applicationId}")
    public LoanApplicationResponse get(@PathVariable String applicationId) {
        return LoanApplicationResponse.from(service.get(applicationId));
    }
}
